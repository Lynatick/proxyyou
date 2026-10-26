package option

import (
	"context"
	"time"
)

// DeferredOutboundOptions contains metadata only. Parameters are read from
// relational storage on first use, not serialized or decoded as JSON.
type DeferredOutboundOptions struct {
	Fingerprint  string
	Network      []string
	Dependencies []string
	Display      string
	Load         func(context.Context) (any, error)
}

type DatabaseSourceOptions struct {
	Location       string
	SettingsHash   string
	Profile        string
	Revision       string
	Close          func() error
	RecordUsage    func(map[string][2]int64)
	Record         func(tag string, delay uint16, unavailable bool, session string, epoch, sequence uint64)
	ReadHistory    func() ([]DatabaseHistory, error)
	Activate       func() error
	NetworkChanged func(uint64)
	ReadSelection  func(string) string
	StoreSelection func(string, string) error
}

type DatabaseHistory struct {
	Tag         string
	Delay       uint16
	Unavailable bool
	Time        time.Time
}
