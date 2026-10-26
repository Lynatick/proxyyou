package endpoint

import (
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
)

func (m *Manager) PruneDatabase(keep map[string]bool) {
	m.access.Lock()
	remaining := make([]adapter.Endpoint, 0, len(m.endpoints))
	var retire []*outbound.Deferred
	for _, entry := range m.endpoints {
		if deferred, ok := entry.(*outbound.Deferred); ok && !keep[entry.Tag()] {
			delete(m.endpointByTag, entry.Tag())
			retire = append(retire, deferred)
		} else {
			remaining = append(remaining, entry)
		}
	}
	m.endpoints = remaining
	m.databaseRetired = append(m.databaseRetired, retire...)
	retired := append([]*outbound.Deferred(nil), m.databaseRetired...)
	m.access.Unlock()
	for _, entry := range retire {
		entry.Retire()
	}
	done := make(map[*outbound.Deferred]bool)
	for _, entry := range retired {
		if !entry.HasLeases() {
			done[entry] = true
		}
	}
	m.access.Lock()
	live := m.databaseRetired[:0]
	for _, entry := range m.databaseRetired {
		if !done[entry] {
			live = append(live, entry)
		}
	}
	m.databaseRetired = live
	m.access.Unlock()
}
