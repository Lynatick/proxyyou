package trafficontrol

import "sync/atomic"

// A compact snapshot visits only servers which actually carried traffic.
func (m *Manager) DatabaseUsage() map[string][2]int64 {
	result := make(map[string][2]int64)
	m.outboundUploadTotal.Range(func(key, value any) bool {
		tag := key.(string)
		current := result[tag]
		current[0] = value.(*atomic.Int64).Load()
		result[tag] = current
		return true
	})
	m.outboundDownloadTotal.Range(func(key, value any) bool {
		tag := key.(string)
		current := result[tag]
		current[1] = value.(*atomic.Int64).Load()
		result[tag] = current
		return true
	})
	return result
}
