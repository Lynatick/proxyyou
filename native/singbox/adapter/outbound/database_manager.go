package outbound

import "github.com/sagernet/sing-box/adapter"

// Removed catalogue entries leave the lookup map immediately. Their leased
// generations survive until streams close; explicit app shutdown still closes
// any remaining retired generations.
func (m *Manager) RetireDatabase(tag string) {
	m.access.Lock()
	out, ok := m.outboundByTag[tag]
	deferred, isDeferred := out.(*Deferred)
	if !ok || !isDeferred {
		m.access.Unlock()
		return
	}
	delete(m.outboundByTag, tag)
	delete(m.dependByTag, tag)
	remaining := make([]adapter.Outbound, 0, len(m.outbounds))
	for _, entry := range m.outbounds {
		if entry != out {
			remaining = append(remaining, entry)
		}
	}
	m.outbounds = remaining
	m.dependByTag = make(map[string][]string)
	for _, entry := range remaining {
		for _, dependency := range entry.Dependencies() {
			m.dependByTag[dependency] = append(m.dependByTag[dependency], entry.Tag())
		}
	}
	m.databaseRetired = append(m.databaseRetired, deferred)
	m.access.Unlock()
	deferred.Retire()
}

func (m *Manager) PruneDatabase(keep map[string]bool) {
	m.access.Lock()
	var retire []*Deferred
	remaining := make([]adapter.Outbound, 0, len(m.outbounds))
	for _, entry := range m.outbounds {
		deferred, ok := entry.(*Deferred)
		if ok && !keep[entry.Tag()] {
			delete(m.outboundByTag, entry.Tag())
			delete(m.dependByTag, entry.Tag())
			retire = append(retire, deferred)
		} else {
			remaining = append(remaining, entry)
		}
	}
	m.outbounds = remaining
	m.dependByTag = make(map[string][]string)
	for _, entry := range remaining {
		for _, dependency := range entry.Dependencies() {
			m.dependByTag[dependency] = append(m.dependByTag[dependency], entry.Tag())
		}
	}
	m.databaseRetired = append(m.databaseRetired, retire...)
	retired := append([]*Deferred(nil), m.databaseRetired...)
	m.access.Unlock()
	for _, entry := range retire {
		entry.Retire()
	}
	done := make(map[*Deferred]bool)
	for _, entry := range retired {
		if !entry.HasLeases() {
			done[entry] = true
		}
	}
	m.access.Lock()
	retained := m.databaseRetired[:0]
	for _, entry := range m.databaseRetired {
		if !done[entry] {
			retained = append(retained, entry)
		}
	}
	m.databaseRetired = retained
	m.access.Unlock()
}
