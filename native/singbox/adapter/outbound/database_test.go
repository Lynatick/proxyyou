package outbound

import (
	"context"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/buf"
	M "github.com/sagernet/sing/common/metadata"
)

type databaseTestOutbound struct {
	Adapter
	closed      atomic.Bool
	mu          sync.Mutex
	connections []net.Conn
}

func (o *databaseTestOutbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	client, server := net.Pipe()
	o.mu.Lock()
	o.connections = append(o.connections, client, server)
	o.mu.Unlock()
	go func() { defer server.Close(); io.Copy(server, server) }()
	return client, nil
}
func (o *databaseTestOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, net.ErrClosed
}
func (o *databaseTestOutbound) Close() error {
	o.closed.Store(true)
	o.mu.Lock()
	defer o.mu.Unlock()
	for _, connection := range o.connections {
		connection.Close()
	}
	return nil
}

func TestDatabaseRefsDoNotCreateTransportsUntilUsed(t *testing.T) {
	pool := NewDatabasePool(2)
	var created atomic.Int32
	factory := func(context.Context, any) (adapter.Outbound, error) {
		created.Add(1)
		return &databaseTestOutbound{Adapter: NewAdapter("socks", "test", []string{"tcp"}, nil)}, nil
	}
	options := &option.DeferredOutboundOptions{Network: []string{"tcp"}, Load: func(context.Context) (any, error) { return struct{}{}, nil }}
	refs := make([]*Deferred, 5000)
	for i := range refs {
		refs[i] = NewDeferred(context.Background(), "socks", "test", options, pool, factory)
		for _, stage := range adapter.ListStartStages {
			if err := refs[i].Start(stage); err != nil {
				t.Fatal(err)
			}
		}
	}
	if created.Load() != 0 {
		t.Fatal("subscription loading created protocol instances")
	}
	if !refs[1].IsReady() {
		t.Fatal("lazy creation failed")
	}
	if created.Load() != 1 {
		t.Fatal("first use did not create exactly one instance")
	}
	for _, ref := range refs {
		ref.Close()
	}
}

func TestDatabaseReplacementKeepsLeasedConnectionAlive(t *testing.T) {
	pool := NewDatabasePool(0)
	var mu sync.Mutex
	var instances []*databaseTestOutbound
	factory := func(context.Context, any) (adapter.Outbound, error) {
		instance := &databaseTestOutbound{Adapter: NewAdapter("socks", "test", []string{"tcp"}, nil)}
		mu.Lock()
		instances = append(instances, instance)
		mu.Unlock()
		return instance, nil
	}
	parameters := func() *option.DeferredOutboundOptions {
		return &option.DeferredOutboundOptions{Network: []string{"tcp"}, Load: func(context.Context) (any, error) { return struct{}{}, nil }}
	}
	ref := NewDeferred(context.Background(), "socks", "test", parameters(), pool, factory)
	defer ref.Close()
	first, err := ref.DialContext(context.Background(), "tcp", M.Socksaddr{})
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	first.SetDeadline(time.Now().Add(3 * time.Second))
	if err = ref.Replace(parameters()); err != nil {
		t.Fatal(err)
	}
	if instances[0].closed.Load() {
		t.Fatal("old leased generation was closed")
	}
	if _, err = first.Write([]byte("still-open")); err != nil {
		t.Fatal(err)
	}
	bytes := make([]byte, len("still-open"))
	if _, err = io.ReadFull(first, bytes); err != nil {
		t.Fatal(err)
	}
	second, err := ref.DialContext(context.Background(), "tcp", M.Socksaddr{})
	if err != nil {
		t.Fatal(err)
	}
	if len(instances) != 2 {
		t.Fatal("new request reused retired generation")
	}
	second.Close()
	first.Close()
	first.Close()
	if !instances[0].closed.Load() {
		t.Fatal("retired generation leaked after last lease")
	}
	if !instances[1].closed.Load() {
		t.Fatal("unleased instance exceeded idle cache limit")
	}
}

func TestDatabaseConcurrentFirstUseCreatesOneGeneration(t *testing.T) {
	var count atomic.Int32
	ref := NewDeferred(context.Background(), "socks", "test", &option.DeferredOutboundOptions{Network: []string{"tcp"}, Load: func(context.Context) (any, error) { return struct{}{}, nil }}, NewDatabasePool(2), func(context.Context, any) (adapter.Outbound, error) {
		count.Add(1)
		return &databaseTestOutbound{Adapter: NewAdapter("socks", "test", []string{"tcp"}, nil)}, nil
	})
	defer ref.Close()
	var group sync.WaitGroup
	for i := 0; i < 20; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			connection, err := ref.DialContext(context.Background(), "tcp", M.Socksaddr{})
			if err != nil {
				t.Error(err)
				return
			}
			connection.Close()
		}()
	}
	group.Wait()
	if count.Load() != 1 {
		t.Fatal("concurrent first use duplicated transport")
	}
}

type databasePacket struct {
	closed chan struct{}
	once   sync.Once
}

func (p *databasePacket) ReadFrom([]byte) (int, net.Addr, error) {
	<-p.closed
	return 0, nil, net.ErrClosed
}
func (p *databasePacket) WriteTo(data []byte, _ net.Addr) (int, error) {
	select {
	case <-p.closed:
		return 0, net.ErrClosed
	default:
		return len(data), nil
	}
}
func (p *databasePacket) Close() error                     { p.once.Do(func() { close(p.closed) }); return nil }
func (p *databasePacket) LocalAddr() net.Addr              { return &net.UDPAddr{} }
func (p *databasePacket) SetDeadline(time.Time) error      { return nil }
func (p *databasePacket) SetReadDeadline(time.Time) error  { return nil }
func (p *databasePacket) SetWriteDeadline(time.Time) error { return nil }

type databaseNoCloser struct {
	Adapter
	peers []net.Conn
}

func (o *databaseNoCloser) DialContext(context.Context, string, M.Socksaddr) (net.Conn, error) {
	client, peer := net.Pipe()
	o.peers = append(o.peers, peer)
	return client, nil
}
func (o *databaseNoCloser) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return &databasePacket{closed: make(chan struct{})}, nil
}

func TestDatabaseUDPGenerationSurvivesReplaceAndExplicitStopClosesAllSockets(t *testing.T) {
	var instances []*databaseNoCloser
	factory := func(context.Context, any) (adapter.Outbound, error) {
		instance := &databaseNoCloser{Adapter: NewAdapter("socks", "server", []string{"tcp", "udp"}, nil)}
		instances = append(instances, instance)
		return instance, nil
	}
	defer func() {
		for _, instance := range instances {
			for _, peer := range instance.peers {
				peer.Close()
			}
		}
	}()
	parameters := func(hash string) *option.DeferredOutboundOptions {
		return &option.DeferredOutboundOptions{Fingerprint: hash, Network: []string{"tcp", "udp"}, Load: func(context.Context) (any, error) { return struct{}{}, nil }}
	}
	ref := NewDeferred(context.Background(), "socks", "server", parameters("one"), NewDatabasePool(2), factory)
	defer ref.Close()
	tcp, err := ref.DialContext(context.Background(), "tcp", M.Socksaddr{})
	if err != nil {
		t.Fatal(err)
	}
	first, err := ref.ListenPacket(context.Background(), M.Socksaddr{})
	if err != nil {
		t.Fatal(err)
	}
	if err = ref.Replace(parameters("two")); err != nil {
		t.Fatal(err)
	}
	if _, err = first.WriteTo([]byte("still-open"), &net.UDPAddr{}); err != nil {
		t.Fatal("old UDP lease closed", err)
	}
	second, err := ref.ListenPacket(context.Background(), M.Socksaddr{})
	if err != nil {
		t.Fatal(err)
	}
	if err = ref.Close(); err != nil {
		t.Fatal(err)
	}
	for _, packet := range []net.PacketConn{first, second} {
		if _, err = packet.WriteTo([]byte("closed"), &net.UDPAddr{}); err == nil {
			t.Fatal("UDP socket survived explicit stop")
		}
	}
	tcp.SetReadDeadline(time.Now().Add(time.Second))
	if _, err = tcp.Read(make([]byte, 1)); err == nil {
		t.Fatal("TCP socket survived explicit stop")
	}
	if ref.HasLeases() {
		t.Fatal("connection leases leaked")
	}
}

type databaseRouteDestination struct{ closed atomic.Bool }

func (r *databaseRouteDestination) WritePacket(*buf.Buffer) error {
	if r.closed.Load() {
		return net.ErrClosed
	}
	return nil
}
func (r *databaseRouteDestination) IsClosed() bool { return r.closed.Load() }
func (r *databaseRouteDestination) Close() error   { r.closed.Store(true); return nil }

type databaseRouteOutbound struct{ databaseNoCloser }

func (o *databaseRouteOutbound) NewDirectRouteConnection(adapter.InboundContext, tun.DirectRouteContext, time.Duration) (tun.DirectRouteDestination, error) {
	return &databaseRouteDestination{}, nil
}

func TestDatabaseDirectRoutePreservesEndpointCapabilityAndLeases(t *testing.T) {
	parameters := func(hash string) *option.DeferredOutboundOptions {
		return &option.DeferredOutboundOptions{Fingerprint: hash, Network: []string{"icmp"}, Load: func(context.Context) (any, error) { return struct{}{}, nil }}
	}
	ref := NewDeferred(context.Background(), "wireguard", "endpoint", parameters("first"), NewDatabasePool(2), func(context.Context, any) (adapter.Outbound, error) {
		return &databaseRouteOutbound{databaseNoCloser: databaseNoCloser{Adapter: NewAdapter("wireguard", "endpoint", []string{"icmp"}, nil)}}, nil
	})
	defer ref.Close()
	first, err := ref.NewDirectRouteConnection(adapter.InboundContext{Network: "icmp"}, nil, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err = ref.Replace(parameters("second")); err != nil {
		t.Fatal(err)
	}
	if err = first.WritePacket(nil); err != nil {
		t.Fatal("old direct route closed during replacement", err)
	}
	second, err := ref.NewDirectRouteConnection(adapter.InboundContext{Network: "icmp"}, nil, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	ref.Close()
	if !first.IsClosed() || !second.IsClosed() || ref.HasLeases() {
		t.Fatal("direct route leases survived explicit stop")
	}
}
