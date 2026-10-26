package clashapi

func (s *Server) DatabaseUsage() map[string][2]int64 { return s.trafficManager.DatabaseUsage() }
