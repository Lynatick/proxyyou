package outbound

import (
	"net"
	"os"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	tun "github.com/sagernet/sing-tun"
)

// Endpoints such as WireGuard also route ICMP. Keep that optional capability
// through the lazy reference and hold its generation until the route closes.
func (d *Deferred) NewDirectRouteConnection(metadata adapter.InboundContext, routeContext tun.DirectRouteContext, timeout time.Duration) (tun.DirectRouteDestination, error) {
	generation, err := d.acquire(d.ctx)
	if err != nil {
		return nil, err
	}
	direct, ok := generation.outbound.(adapter.DirectRouteOutbound)
	if !ok {
		d.release(generation, nil)
		return nil, os.ErrInvalid
	}
	destination, err := direct.NewDirectRouteConnection(metadata, routeContext, timeout)
	if err != nil {
		d.release(generation, nil)
		return nil, err
	}
	result := &databaseRoute{DirectRouteDestination: destination}
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

type databaseRoute struct {
	tun.DirectRouteDestination
	once    sync.Once
	release func()
}

func (r *databaseRoute) Close() (err error) {
	r.once.Do(func() { err = r.DirectRouteDestination.Close(); r.release() })
	return
}
