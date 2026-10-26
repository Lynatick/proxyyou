package balancer

import (
	"fmt"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
)

func (s *Balancer) databaseStrategy() Strategy {
	s.databaseMu.RLock()
	defer s.databaseMu.RUnlock()
	return s.strategyFn
}
func (s *Balancer) RefreshDatabase(options option.BalancerOutboundOptions) error {
	outbounds := make([]adapter.Outbound, 0, len(options.Outbounds))
	for _, tag := range options.Outbounds {
		out, ok := s.outbound.Outbound(tag)
		if !ok {
			return fmt.Errorf("database balancer member not found: %s", tag)
		}
		outbounds = append(outbounds, out)
	}
	strategy := newHealthyStrategy(outbounds, options)
	strategy.available = func(tag string) bool { return !s.monitor.AvailabilityFailed(tag) }
	s.databaseMu.Lock()
	s.strategyFn = strategy
	s.tags = append([]string(nil), options.Outbounds...)
	s.options = options
	s.databaseMu.Unlock()
	return nil
}

func (s *Balancer) Dependencies() []string { return s.All() }
