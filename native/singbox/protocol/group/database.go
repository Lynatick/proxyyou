package group

import (
	"fmt"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
)

func (s *Selector) RefreshDatabase(options option.SelectorOutboundOptions) error {
	outbounds := make(map[string]adapter.Outbound, len(options.Outbounds))
	for _, tag := range options.Outbounds {
		out, ok := s.outbound.Outbound(tag)
		if !ok {
			return fmt.Errorf("database selector member not found: %s", tag)
		}
		outbounds[tag] = out
	}
	if len(outbounds) == 0 {
		return fmt.Errorf("database selector has no members")
	}
	current := s.selected.Load()
	var selected adapter.Outbound
	s.databaseMu.RLock()
	oldSource := s.databaseSource
	s.databaseMu.RUnlock()
	if options.DatabaseSource != nil && (oldSource == nil || oldSource.Profile != options.DatabaseSource.Profile) {
		if options.DatabaseSource.ReadSelection != nil {
			selected = outbounds[options.DatabaseSource.ReadSelection(s.Tag())]
		}
		current = nil
	}
	if selected == nil && current != nil {
		selected = outbounds[current.Tag()]
	}
	if selected == nil {
		selected = outbounds[options.Default]
	}
	if selected == nil {
		selected = outbounds[options.Outbounds[0]]
	}
	s.databaseMu.Lock()
	s.outbounds = outbounds
	s.tags = append([]string(nil), options.Outbounds...)
	s.databaseSource = options.DatabaseSource
	s.defaultTag = options.Default
	s.selected.Store(selected)
	s.databaseMu.Unlock()
	return nil
}

func (s *Selector) Dependencies() []string { return s.All() }
