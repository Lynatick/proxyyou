package monitoring

import (
	"context"
	"sync"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
)

func (m *OutboundMonitoring) state(tag string) *outboundState {
	value, _ := m.lookupState(tag)
	return value
}
func (m *OutboundMonitoring) lookupState(tag string) (*outboundState, bool) {
	m.catalogMu.RLock()
	defer m.catalogMu.RUnlock()
	value, ok := m.outbounds[tag]
	return value, ok
}
func (m *OutboundMonitoring) statesCount() int {
	m.catalogMu.RLock()
	defer m.catalogMu.RUnlock()
	return len(m.outbounds)
}
func (m *OutboundMonitoring) statesSnapshot() map[string]*outboundState {
	m.catalogMu.RLock()
	defer m.catalogMu.RUnlock()
	snapshot := make(map[string]*outboundState, len(m.outbounds))
	for tag, value := range m.outbounds {
		snapshot[tag] = value
	}
	return snapshot
}
func (m *OutboundMonitoring) group(tag string) *groupState {
	value, _ := m.lookupGroup(tag)
	return value
}
func (m *OutboundMonitoring) lookupGroup(tag string) (*groupState, bool) {
	m.catalogMu.RLock()
	defer m.catalogMu.RUnlock()
	value, ok := m.groups[tag]
	return value, ok
}
func (m *OutboundMonitoring) groupsCount() int {
	m.catalogMu.RLock()
	defer m.catalogMu.RUnlock()
	return len(m.groups)
}
func (m *OutboundMonitoring) groupsSnapshot() map[string]*groupState {
	m.catalogMu.RLock()
	defer m.catalogMu.RUnlock()
	snapshot := make(map[string]*groupState, len(m.groups))
	for tag, value := range m.groups {
		snapshot[tag] = value
	}
	return snapshot
}
func (m *OutboundMonitoring) database() *option.DatabaseSourceOptions {
	m.databaseMu.RLock()
	defer m.databaseMu.RUnlock()
	return m.databaseSource
}
func (g *groupState) membersSnapshot() map[string]struct{} {
	g.membersMu.RLock()
	defer g.membersMu.RUnlock()
	snapshot := make(map[string]struct{}, len(g.outbounds))
	for tag := range g.outbounds {
		snapshot[tag] = struct{}{}
	}
	return snapshot
}
func (g *groupState) memberCount() int {
	g.membersMu.RLock()
	defer g.membersMu.RUnlock()
	return len(g.outbounds)
}

func (m *OutboundMonitoring) makeDatabaseGroup(tag string) *groupState {
	m.catalogMu.Lock()
	if existing := m.groups[tag]; existing != nil {
		m.catalogMu.Unlock()
		return existing
	}
	group := &groupState{tag: tag, outbounds: make(map[string]struct{}), observer: NewBroadcaster[GroupEvent](m.ctx), notifyCh: make(chan struct{}, 1)}
	m.groups[tag] = group
	m.catalogMu.Unlock()
	if m.started {
		m.schedulerWG.Add(1)
		go m.groupNotifierLoop(group)
	}
	return group
}
func (m *OutboundMonitoring) EnsureDatabaseGroups(tags []string) {
	for _, tag := range tags {
		m.makeDatabaseGroup(tag)
	}
}

// Maps are swapped as snapshots; in-flight tasks keep their old epoch and can
// complete without applying results to the new revision. Existing observers
// stay attached to group objects and established client sockets are untouched.
func (m *OutboundMonitoring) ReloadDatabaseCatalog(source *option.DatabaseSourceOptions, outbounds []adapter.Outbound, changed map[string]bool) {
	m.sourceEpochMu.Lock()
	oldEpoch := m.networkEpoch.Load()
	states := make(map[string]*outboundState, len(outbounds))
	order := make([]string, 0, len(outbounds))
	for _, out := range outbounds {
		state := &outboundState{outbound: out, invalid: true, from_cache: true, dependencies: out.Dependencies()}
		if old := m.state(out.Tag()); old != nil && !changed[out.Tag()] {
			old.mu.Lock()
			state.history = old.history
			state.availabilityFailed = old.availabilityFailed
			state.proofFailed = old.proofFailed
			state.from_cache = old.from_cache
			state.invalid = old.invalid
			state.lastURL = old.lastURL
			old.mu.Unlock()
		}
		states[out.Tag()] = state
		order = append(order, out.Tag())
	}
	membership := map[string]map[string]struct{}{"": {}}
	for tag, state := range states {
		membership[""][tag] = struct{}{}
		state.groupTags = []string{""}
		for _, dependency := range state.dependencies {
			if parent := states[dependency]; parent != nil {
				parent.dependenciesInverse = append(parent.dependenciesInverse, tag)
			}
		}
	}
	for _, out := range outbounds {
		if group, ok := out.(adapter.OutboundGroup); ok {
			members := make(map[string]struct{})
			for _, tag := range group.All() {
				if state := states[tag]; state != nil {
					members[tag] = struct{}{}
					state.groupTags = append(state.groupTags, group.Tag())
				}
			}
			membership[group.Tag()] = members
			m.makeDatabaseGroup(group.Tag())
		}
	}
	for tag, group := range m.groupsSnapshot() {
		group.membersMu.Lock()
		group.outbounds = membership[tag]
		if group.outbounds == nil {
			group.outbounds = make(map[string]struct{})
		}
		group.membersMu.Unlock()
	}
	m.catalogMu.Lock()
	m.outbounds = states
	m.outboundOrder = order
	m.catalogMu.Unlock()
	m.databaseMu.Lock()
	m.databaseSource = source
	m.databaseMu.Unlock()
	epoch := m.networkEpoch.Add(1)
	if source.NetworkChanged != nil {
		source.NetworkChanged(epoch)
	}
	pending := m.taskQueue().drain()
	if source.Record != nil {
		for tag, state := range states {
			state.mu.Lock()
			history, failed := state.history, state.availabilityFailed
			state.mu.Unlock()
			if !history.Time.IsZero() {
				source.Record(tag, history.Delay, failed, "", epoch, 0)
			}
		}
	}
	m.sourceEpochMu.Unlock()
	for _, task := range pending {
		m.completeTask(task, adapter.URLTestHistory{}, context.Canceled, oldEpoch)
	}
	groups := make([]string, 0, len(membership))
	for tag := range membership {
		groups = append(groups, tag)
	}
	m.emitGroupEvent(groups)
	m.startCycleOnce()
}

// Referenced by fields added to the existing structs in the integration patch.
var _ sync.Locker = (*sync.Mutex)(nil)
