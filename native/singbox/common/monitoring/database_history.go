package monitoring

import "github.com/sagernet/sing-box/adapter"

func (m *OutboundMonitoring) DatabaseSelectedHistory(tag string) *adapter.URLTestHistory {
	state, ok := m.lookupState(tag)
	if !ok {
		return nil
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	history := state.history
	history.IsFromCache = state.from_cache
	if state.availabilityFailed {
		history.Delay = TimeoutDelay
	}
	return &history
}
