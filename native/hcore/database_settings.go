package hcore

import (
	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/configdb"
)

// Builders patch a private snapshot. A validation or import must never mutate
// the live settings while another request is building a connection.
func (h *HiddifyInstance) settingsSnapshot() (*config.HiddifyOptions, error) {
	h.settingsMu.RLock()
	defer h.settingsMu.RUnlock()
	original := h.HiddifyOptions
	if original == nil {
		return config.DefaultHiddifyOptions(), nil
	}
	codec := configdb.NewCodec(original)
	fields, err := codec.Encode(original)
	if err != nil {
		return nil, err
	}
	var result config.HiddifyOptions
	if err = codec.Decode(fields, &result); err != nil {
		return nil, err
	}
	return &result, nil
}
func (h *HiddifyInstance) tunEnabled() bool {
	h.settingsMu.RLock()
	defer h.settingsMu.RUnlock()
	return h.HiddifyOptions != nil && h.HiddifyOptions.EnableTun
}
