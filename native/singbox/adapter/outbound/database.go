package outbound

import (
	"container/list"
	"context"
	"fmt"
	"io"
	"net"
	"slices"
	"sync"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common"
	M "github.com/sagernet/sing/common/metadata"
)

// The idle cache is bounded; active connections hold explicit leases. No scan
// of a large subscription creates one cleanup goroutine/timer per server.
type DatabasePool struct {
	mu    sync.Mutex
	idle  list.List
	items map[*Deferred]*list.Element
	limit int
}

func NewDatabasePool(limit int) *DatabasePool {
	return &DatabasePool{items: make(map[*Deferred]*list.Element), limit: limit}
}
func (p *DatabasePool) used(out *Deferred) {
	p.mu.Lock()
	if element := p.items[out]; element != nil {
		p.idle.Remove(element)
		delete(p.items, out)
	}
	p.mu.Unlock()
}
func (p *DatabasePool) released(out *Deferred) {
	p.mu.Lock()
	if element := p.items[out]; element != nil {
		p.idle.MoveToBack(element)
	} else {
		p.items[out] = p.idle.PushBack(out)
	}
	var evict []*Deferred
	for p.idle.Len() > p.limit {
		element := p.idle.Front()
		item := element.Value.(*Deferred)
		p.idle.Remove(element)
		delete(p.items, item)
		evict = append(evict, item)
	}
	p.mu.Unlock()
	for _, item := range evict {
		item.evict()
	}
}

type databaseGeneration struct {
	outbound    adapter.Outbound
	leases      int
	retired     bool
	closed      bool
	connections map[io.Closer]struct{}
}
type Deferred struct {
	Adapter
	mu         sync.Mutex
	ctx        context.Context
	options    option.DeferredOutboundOptions
	factory    func(context.Context, any) (adapter.Outbound, error)
	pool       *DatabasePool
	generation *databaseGeneration
	retired    []*databaseGeneration
	stage      adapter.StartStage
	started    bool
	closed     bool
}

func NewDeferred(ctx context.Context, kind, tag string, options *option.DeferredOutboundOptions, pool *DatabasePool, factory func(context.Context, any) (adapter.Outbound, error)) *Deferred {
	return &Deferred{Adapter: NewAdapter(kind, tag, append([]string(nil), options.Network...), append([]string(nil), options.Dependencies...)), ctx: ctx, options: *options, pool: pool, factory: factory}
}
func (d *Deferred) Start(stage adapter.StartStage) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return net.ErrClosed
	}
	if d.started && stage <= d.stage {
		return nil
	}
	if d.generation != nil {
		if err := adapter.LegacyStart(d.generation.outbound, stage); err != nil {
			return err
		}
	}
	d.stage = stage
	d.started = true
	return nil
}
func (d *Deferred) DisplayType() string { d.mu.Lock(); defer d.mu.Unlock(); return d.options.Display }
func (d *Deferred) Fingerprint() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.options.Fingerprint
}
func (d *Deferred) acquire(ctx context.Context) (*databaseGeneration, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	d.pool.used(d)
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return nil, net.ErrClosed
	}
	if d.generation == nil {
		options, err := d.options.Load(ctx)
		if err != nil {
			return nil, err
		}
		instance, err := d.factory(d.ctx, options)
		if err != nil {
			return nil, err
		}
		if d.started {
			for _, stage := range adapter.ListStartStages {
				if stage > d.stage {
					break
				}
				if err = adapter.LegacyStart(instance, stage); err != nil {
					common.Close(instance)
					return nil, err
				}
			}
		}
		d.generation = &databaseGeneration{outbound: instance, connections: make(map[io.Closer]struct{})}
	}
	d.generation.leases++
	return d.generation, nil
}
func (d *Deferred) release(generation *databaseGeneration, connection io.Closer) {
	d.mu.Lock()
	delete(generation.connections, connection)
	generation.leases--
	if generation.leases < 0 {
		d.mu.Unlock()
		panic("negative database outbound lease")
	}
	closeNow := generation.leases == 0 && (generation.retired || d.closed) && !generation.closed
	if closeNow {
		generation.closed = true
	}
	if generation.leases == 0 && generation.retired {
		for i, item := range d.retired {
			if item == generation {
				d.retired = append(d.retired[:i], d.retired[i+1:]...)
				break
			}
		}
	}
	idle := generation.leases == 0 && generation == d.generation && !generation.retired && !d.closed
	d.mu.Unlock()
	if closeNow {
		common.Close(generation.outbound)
	}
	if idle {
		d.pool.released(d)
	}
}
func (d *Deferred) evict() {
	d.mu.Lock()
	var instance adapter.Outbound
	if generation := d.generation; generation != nil && generation.leases == 0 && !generation.closed {
		generation.closed = true
		instance = generation.outbound
		d.generation = nil
	}
	d.mu.Unlock()
	if instance != nil {
		common.Close(instance)
	}
}
func (d *Deferred) IsReady() bool {
	generation, err := d.acquire(d.ctx)
	if err != nil {
		return false
	}
	defer d.release(generation, nil)
	return generation.outbound.IsReady()
}
func (d *Deferred) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	generation, err := d.acquire(ctx)
	if err != nil {
		return nil, err
	}
	connection, err := generation.outbound.DialContext(ctx, network, destination)
	if err != nil {
		d.release(generation, nil)
		return nil, err
	}
	result := &databaseConn{Conn: connection}
	result.release = func() { d.release(generation, result) }
	d.mu.Lock()
	closed := generation.closed
	if !closed {
		generation.connections[result] = struct{}{}
	}
	d.mu.Unlock()
	if closed {
		result.Close()
		return nil, net.ErrClosed
	}
	return result, nil
}
func (d *Deferred) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	generation, err := d.acquire(ctx)
	if err != nil {
		return nil, err
	}
	connection, err := generation.outbound.ListenPacket(ctx, destination)
	if err != nil {
		d.release(generation, nil)
		return nil, err
	}
	result := &databasePacketConn{PacketConn: connection}
	result.release = func() { d.release(generation, result) }
	d.mu.Lock()
	closed := generation.closed
	if !closed {
		generation.connections[result] = struct{}{}
	}
	d.mu.Unlock()
	if closed {
		result.Close()
		return nil, net.ErrClosed
	}
	return result, nil
}

// Replacing parameters leaves leased generations alive until their last
// connection closes. New requests immediately use the new generation.
func (d *Deferred) Replace(options *option.DeferredOutboundOptions) error {
	d.pool.used(d)
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return net.ErrClosed
	}
	if !slices.Equal(d.dependencies, options.Dependencies) || !slices.Equal(d.network, options.Network) {
		d.mu.Unlock()
		return fmt.Errorf("dependency change requires staged group reload")
	}
	if d.options.Fingerprint != "" && d.options.Fingerprint == options.Fingerprint {
		d.options = *options
		d.mu.Unlock()
		return nil
	}
	old := d.generation
	d.options = *options
	d.generation = nil
	var closeNow adapter.Outbound
	if old != nil {
		old.retired = true
		if old.leases == 0 && !old.closed {
			old.closed = true
			closeNow = old.outbound
		} else {
			d.retired = append(d.retired, old)
		}
	}
	d.mu.Unlock()
	if closeNow != nil {
		common.Close(closeNow)
	}
	return nil
}
func (d *Deferred) HasLeases() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.generation != nil && d.generation.leases > 0 {
		return true
	}
	for _, generation := range d.retired {
		if generation.leases > 0 {
			return true
		}
	}
	return false
}
func (d *Deferred) Retire() error {
	d.pool.used(d)
	d.mu.Lock()
	d.closed = true
	var closeNow adapter.Outbound
	if generation := d.generation; generation != nil {
		generation.retired = true
		if generation.leases == 0 && !generation.closed {
			generation.closed = true
			closeNow = generation.outbound
		}
	}
	d.mu.Unlock()
	if closeNow != nil {
		return common.Close(closeNow)
	}
	return nil
}
func (d *Deferred) Close() error {
	d.pool.used(d)
	d.mu.Lock()
	d.closed = true
	generations := append([]*databaseGeneration(nil), d.retired...)
	if d.generation != nil {
		generations = append(generations, d.generation)
	}
	var instances []adapter.Outbound
	var connections []io.Closer
	for _, generation := range generations {
		if !generation.closed {
			generation.closed = true
			instances = append(instances, generation.outbound)
		}
		for connection := range generation.connections {
			connections = append(connections, connection)
		}
	}
	d.generation = nil
	d.retired = nil
	d.mu.Unlock()
	for _, connection := range connections {
		connection.Close()
	}
	for _, instance := range instances {
		common.Close(instance)
	}
	return nil
}

type databaseConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *databaseConn) Close() (err error) {
	c.once.Do(func() { err = c.Conn.Close(); c.release() })
	return
}
func (c *databaseConn) Upstream() any { return c.Conn }

type databasePacketConn struct {
	net.PacketConn
	once    sync.Once
	release func()
}

func (c *databasePacketConn) Close() (err error) {
	c.once.Do(func() { err = c.PacketConn.Close(); c.release() })
	return
}
func (c *databasePacketConn) Upstream() any { return c.PacketConn }
