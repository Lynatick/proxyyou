package hcore

import (
	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
	G "github.com/sagernet/sing-box/protocol/group"
	"strings"
)

// The home screen needs only the selected path, not a copy of every server
// and its history after each completed probe in a large subscription.
func (h *HiddifyInstance) proxySnapshot(monitor *monitoring.OutboundMonitoring, onlyMain bool) *OutboundGroupList {
	if !onlyMain {
		return h.GetAllProxiesInfo(monitor.OutboundsHistory(""), false)
	}
	box := h.Box()
	result := &OutboundGroupList{}
	if box == nil {
		return result
	}
	lookup := func(tag string) (adapter.Outbound, bool) {
		if out, ok := box.Outbound().Outbound(tag); ok {
			return out, true
		}
		return box.Endpoint().Get(tag)
	}
	queue := []string{config.OutboundSelectTag}
	seen := make(map[string]bool)
	for len(queue) > 0 {
		tag := queue[0]
		queue = queue[1:]
		if seen[tag] {
			continue
		}
		seen[tag] = true
		value, ok := lookup(tag)
		if !ok {
			continue
		}
		group, ok := value.(adapter.OutboundGroup)
		if !ok {
			continue
		}
		selected := group.Now()
		out, ok := lookup(selected)
		if !ok {
			continue
		}
		realTag := monitoring.RealTag(out)
		if realTag == "" {
			realTag = out.Tag()
		}
		info := h.GetProxyInfo(monitor.DatabaseSelectedHistory(realTag), out)
		info.IsSelected = true
		info.IsVisible = !strings.Contains(selected, "§hide§")
		if info.GroupSelectedTagDisplay != nil && info.TagDisplay != *info.GroupSelectedTagDisplay {
			info.TagDisplay += " → " + *info.GroupSelectedTagDisplay
		}
		_, selectable := group.(*G.Selector)
		entry := &OutboundGroup{Tag: tag, Type: group.Type(), Selected: selected, Selectable: selectable, Items: []*OutboundInfo{info}}
		if info.IsGroup {
			queue = append(queue, selected)
		}
		if tag == config.OutboundSelectTag {
			if warp, exists := lookup(config.WARPConfigTag); exists {
				warpInfo := h.GetProxyInfo(monitor.DatabaseSelectedHistory(warp.Tag()), warp)
				warpInfo.TagDisplay = config.WARPConfigTag + " → " + info.TagDisplay
				entry.Selected = warp.Tag()
				entry.Items = append([]*OutboundInfo{warpInfo}, entry.Items...)
			}
		}
		result.Items = append(result.Items, entry)
	}
	return result
}
