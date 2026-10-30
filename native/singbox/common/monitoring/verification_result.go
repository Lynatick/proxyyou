package monitoring

import (
	"fmt"
	"time"
)

// A separate proof generation keeps unrelated background pings from invalidating
// a video check. A stale result cannot clear or blacklist a newer generation.
func (m *OutboundMonitoring) CompleteVerification(tag, ticket string, success bool) bool {
	m.sourceEpochMu.RLock()
	defer m.sourceEpochMu.RUnlock()
	if m.ctx.Err() != nil {
		return false
	}
	state := m.state(tag)
	if state == nil {
		return false
	}
	state.mu.Lock()
	expected := fmt.Sprintf("%d:%d:%s", m.networkEpoch.Load(), state.verificationSequence, tag)
	if ticket != expected || state.verificationSequence == 0 || success && !state.verificationReady {
		state.mu.Unlock()
		return false
	}
	state.verificationSequence++ // Consume the ticket; late results cannot reverse this decision.
	state.verificationReady = false
	state.proofFailed = !success
	state.availabilityFailed = !success
	state.history.Time = time.Now()
	state.from_cache = false
	m.cacheDirty.Store(true)
	if db := m.database(); db != nil && db.Record != nil {
		delay := state.history.Delay
		if !success {
			delay = TimeoutDelay
		}
		db.Record(tag, delay, !success, ticket, m.networkEpoch.Load(), state.availabilitySequence)
	}
	groups := append([]string(nil), state.groupTags...)
	state.mu.Unlock()
	m.emitGroupEvent(groups)
	return true
}

// Scan metadata under its read lock without allocating a million-row snapshot.
func (m *OutboundMonitoring) NextVerificationTag(failed string) string {
	m.sourceEpochMu.RLock()
	defer m.sourceEpochMu.RUnlock()
	m.catalogMu.RLock()
	defer m.catalogMu.RUnlock()
	main := m.groups["select"]
	if main == nil {
		return ""
	}
	main.membersMu.RLock()
	defer main.membersMu.RUnlock()
	fallback := ""
	for _, tag := range m.outboundOrder {
		if _, selectable := main.outbounds[tag]; !selectable {
			continue
		}
		if tag == failed {
			continue
		}
		if _, group := m.groups[tag]; group {
			continue
		}
		state := m.outbounds[tag]
		if state == nil {
			continue
		}
		state.mu.Lock()
		allowed := !state.availabilityFailed
		fresh := !state.from_cache && state.history.Delay > 0 && state.history.Delay < TimeoutDelay
		state.mu.Unlock()
		if !allowed {
			continue
		}
		if fresh {
			return tag
		}
		if fallback == "" {
			fallback = tag
		}
	}
	return fallback
}
