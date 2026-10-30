package balancer

import (
	"github.com/sagernet/sing-box/adapter"
	N "github.com/sagernet/sing/common/network"
)

// Refresh and advance the selected label without closing established sockets.
func (s *Balancer) SelectAfterVerificationFailure() string {
	strategy := s.databaseStrategy()
	if strategy == nil || s.monitor == nil {
		return ""
	}
	strategy.UpdateOutboundsInfo(s.monitor.OutboundsHistory(s.Tag()))
	next := strategy.Select(adapter.InboundContext{}, N.NetworkTCP, true)
	if next == nil {
		return ""
	}
	s.reportSelection(next.Tag())
	return next.Tag()
}
