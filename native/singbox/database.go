package box

import (
	"github.com/sagernet/sing-box/option"
	"time"
)

func (s *Box) DatabaseSource() *option.DatabaseSourceOptions {
	s.databaseMu.RLock()
	defer s.databaseMu.RUnlock()
	return s.databaseSource
}
func (s *Box) ReplaceDatabaseSource(source *option.DatabaseSourceOptions) *option.DatabaseSourceOptions {
	s.databaseMu.Lock()
	previous := s.databaseSource
	s.databaseSource = source
	s.databaseClose = source.Close
	s.databaseActivate = source.Activate
	s.databaseMu.Unlock()
	return previous
}

func (s *Box) databaseUsageLoop() {
	defer s.databaseUsageWG.Done()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-ticker.C:
			if source := s.DatabaseSource(); source != nil && source.RecordUsage != nil && s.databaseUsage != nil {
				source.RecordUsage(s.databaseUsage())
			}
		}
	}
}
