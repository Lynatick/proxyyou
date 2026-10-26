package libbox

import (
	"context"
	"fmt"
	"strconv"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common"
	"github.com/sagernet/sing/service"
)

type ConfigDatabaseMetadata struct {
	Tag, Display          string
	Network, Dependencies []string
	IsGroup               bool
}

// Import inspection retains only lightweight references. One temporary
// protocol object at a time supplies validated metadata and is then closed.
func InspectDatabaseImport(ctx context.Context, options *option.Options) ([]ConfigDatabaseMetadata, error) {
	ctx = service.ContextWithRegistry(ctx, service.NewRegistry())
	ctx, cancel := context.WithCancel(FromContext(ctx, nil))
	defer cancel()
	headers := *options
	headers.DatabaseSource = nil
	headers.RawMessage = nil
	headers.Log = &option.LogOptions{Disabled: true}
	headers.Outbounds = append([]option.Outbound(nil), options.Outbounds...)
	headers.Endpoints = append([]option.Endpoint(nil), options.Endpoints...)
	placeholder := func() *option.DeferredOutboundOptions {
		return &option.DeferredOutboundOptions{Network: []string{"tcp", "udp"}, Load: func(context.Context) (any, error) {
			return nil, fmt.Errorf("import inspection reference cannot start a transport")
		}}
	}
	for i := range headers.Outbounds {
		headers.Outbounds[i].Options = placeholder()
	}
	for i := range headers.Endpoints {
		headers.Endpoints[i].Options = placeholder()
	}
	instance, err := box.New(box.Options{Context: ctx, Options: headers})
	if err != nil {
		return nil, err
	}
	defer instance.Close()
	result := make([]ConfigDatabaseMetadata, 0, len(options.Outbounds)+len(options.Endpoints))
	logger := log.NewNOPFactory().Logger()
	add := func(out adapter.Outbound) {
		_, group := out.(adapter.OutboundGroup)
		result = append(result, ConfigDatabaseMetadata{Tag: out.Tag(), Display: out.DisplayType(), Network: append([]string(nil), out.Network()...), Dependencies: append([]string(nil), out.Dependencies()...), IsGroup: group})
		common.Close(out)
	}
	registry := service.FromContext[adapter.OutboundRegistry](ctx)
	for index, entry := range options.Outbounds {
		if err = ctx.Err(); err != nil {
			return nil, err
		}
		tag := entry.Tag
		if tag == "" {
			tag = strconv.Itoa(index)
		}
		out, createErr := registry.CreateOutbound(ctx, instance.Router(), logger, tag, entry.Type, entry.Options)
		if createErr != nil {
			out, createErr = registry.CreateOutbound(ctx, instance.Router(), logger, tag, C.TypeHInvalidConfig, &option.HInvalidOptions{InvalidConfig: entry.Options, Err: createErr})
		}
		if createErr != nil {
			return nil, createErr
		}
		add(out)
	}
	endpoints := service.FromContext[adapter.EndpointRegistry](ctx)
	for index, entry := range options.Endpoints {
		if err = ctx.Err(); err != nil {
			return nil, err
		}
		tag := entry.Tag
		if tag == "" {
			tag = strconv.Itoa(index)
		}
		out, createErr := endpoints.Create(ctx, instance.Router(), logger, tag, entry.Type, entry.Options)
		if createErr != nil {
			return nil, createErr
		}
		add(out)
	}
	return result, nil
}
