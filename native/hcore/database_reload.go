package hcore

import (
	"context"
	"errors"
	"fmt"
	boxlib "github.com/sagernet/sing-box"

	"github.com/hiddify/hiddify-core/v2/configdb"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/monitoring"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/group"
	"github.com/sagernet/sing-box/protocol/group/balancer"
)

// A subscription change updates metadata/providers and group membership inside
// the live Box. No inbound, router, TUN, system proxy or client socket is stopped.
func reloadDatabase(ctx context.Context, in *StartRequest) (*CoreInfoResponse, bool, error) {
	_, database, locationErr := configdb.ParseLocation(in.ConfigPath)
	if !database {
		return nil, false, nil
	}
	if locationErr != nil {
		return nil, true, locationErr
	}
	static.lock.Lock()
	defer static.lock.Unlock()
	box := static.Box()
	if box == nil || static.CoreState != CoreStates_STARTED {
		return nil, false, nil
	}
	previous := box.DatabaseSource()
	if previous == nil {
		return nil, false, nil
	}
	options, err := BuildConfig(ctx, in)
	if err != nil {
		return nil, true, err
	}
	source := options.DatabaseSource
	if source == nil {
		return nil, true, fmt.Errorf("database revision did not provide a source")
	}
	committed := false
	defer func() {
		if !committed {
			source.Close()
		}
	}()
	// Changes to listeners/DNS/routing still use the existing explicit restart
	// path. A pure subscription update never tears down the running service.
	if source.SettingsHash != previous.SettingsHash {
		return nil, false, nil
	}
	options.DatabaseSource = nil
	validationErr := libbox.CheckConfigOptions(options)
	options.DatabaseSource = source
	if validationErr != nil {
		return nil, true, validationErr
	}
	monitor := monitoring.Get(static.Context())
	if monitor == nil {
		return nil, true, fmt.Errorf("database monitoring not running")
	}
	// Retain an independent typed snapshot for recovery before mutating providers.
	// The old source stays pinned throughout staging.
	rollbackRequest := *in
	rollbackRequest.ConfigPath = previous.Location
	rollbackOptions, err := BuildConfig(ctx, &rollbackRequest)
	if err != nil {
		return nil, true, err
	}
	rollbackSource := rollbackOptions.DatabaseSource
	rollbackOwned := false
	defer func() {
		if !rollbackOwned {
			rollbackSource.Close()
		}
	}()
	monitor.EnsureDatabaseGroups([]string{"select", "balance", "lowest"})
	active, applyErr := applyDatabaseOptions(box, options)
	if applyErr == nil {
		applyErr = source.Activate()
	}
	if applyErr != nil {
		restored, restoreErr := applyDatabaseOptions(box, rollbackOptions)
		if restoreErr == nil {
			restoreErr = rollbackSource.Activate()
		}
		if restoreErr == nil {
			monitor.ReloadDatabaseCatalog(rollbackSource, restored, nil)
			box.ReplaceDatabaseSource(rollbackSource)
			previous.Close()
			rollbackOwned = true
		} else {
			// Keep all loaders owned until an explicit stop if recovery itself fails.
			// This prevents a partially applied provider from reading a closed DB.
			originalClose := source.Close
			source.Close = func() error { return errors.Join(originalClose(), rollbackSource.Close(), previous.Close()) }
			box.ReplaceDatabaseSource(source)
			rollbackOwned = true
			committed = true
		}
		return nil, true, errors.Join(applyErr, restoreErr)
	}
	changed := make(map[string]bool)
	oldFingerprints := databaseFingerprints(rollbackOptions)
	for _, out := range active {
		if reference, ok := out.(*outbound.Deferred); ok {
			changed[out.Tag()] = reference.Fingerprint() != oldFingerprints[out.Tag()]
		}
	}
	monitor.ReloadDatabaseCatalog(source, active, changed)
	box.ReplaceDatabaseSource(source)
	previous.Close()
	static.previousStartRequest = in
	saveLastStartRequest(in)
	committed = true
	return &CoreInfoResponse{CoreState: CoreStates_STARTED, MessageType: MessageType_EMPTY}, true, nil
}

func databaseFingerprints(options *option.Options) map[string]string {
	values := make(map[string]string, len(options.Outbounds)+len(options.Endpoints))
	for _, out := range options.Outbounds {
		if value, ok := out.Options.(*option.DeferredOutboundOptions); ok {
			values[out.Tag] = value.Fingerprint
		}
	}
	for _, out := range options.Endpoints {
		if value, ok := out.Options.(*option.DeferredOutboundOptions); ok {
			values[out.Tag] = value.Fingerprint
		}
	}
	return values
}
func applyDatabaseOptions(box *boxlib.Box, options *option.Options) ([]adapter.Outbound, error) {
	var err error
	keepOut := make(map[string]bool, len(options.Outbounds))
	keepEnd := make(map[string]bool, len(options.Endpoints))
	// Providers before groups: added members must exist before group Start.
	for _, out := range options.Outbounds {
		keepOut[out.Tag] = true
		if _, isSelector := out.Options.(*option.SelectorOutboundOptions); isSelector {
			continue
		}
		if _, isBalancer := out.Options.(*option.BalancerOutboundOptions); isBalancer {
			continue
		}
		if deferred, ok := out.Options.(*option.DeferredOutboundOptions); ok {
			if current, exists := box.Outbound().Outbound(out.Tag); exists {
				if reference, isDeferred := current.(*outbound.Deferred); isDeferred && current.Type() == out.Type {
					if err = reference.Replace(deferred); err == nil {
						continue
					}
				}
			}
			if err = box.Outbound().Create(static.Context(), box.Router(), box.Logger(), out.Tag, out.Type, deferred); err != nil {
				return nil, err
			}
		}
	}
	for _, endpoint := range options.Endpoints {
		keepEnd[endpoint.Tag] = true
		if deferred, ok := endpoint.Options.(*option.DeferredOutboundOptions); ok {
			if current, exists := box.Endpoint().Get(endpoint.Tag); exists {
				if reference, isDeferred := current.(*outbound.Deferred); isDeferred && current.Type() == endpoint.Type {
					if err = reference.Replace(deferred); err == nil {
						continue
					}
				}
			}
			if err = box.Endpoint().Create(static.Context(), box.Router(), box.Logger(), endpoint.Tag, endpoint.Type, deferred); err != nil {
				return nil, err
			}
		}
	}
	for _, out := range options.Outbounds {
		switch parameters := out.Options.(type) {
		case *option.BalancerOutboundOptions:
			current, exists := box.Outbound().Outbound(out.Tag)
			if exists {
				if current, ok := current.(*balancer.Balancer); ok {
					if err = current.RefreshDatabase(*parameters); err != nil {
						return nil, err
					}
					continue
				}
			}
			if err = box.Outbound().Create(static.Context(), box.Router(), box.Logger(), out.Tag, out.Type, parameters); err != nil {
				return nil, err
			}
		case *option.SelectorOutboundOptions:
			current, exists := box.Outbound().Outbound(out.Tag)
			if exists {
				if current, ok := current.(*group.Selector); ok {
					if err = current.RefreshDatabase(*parameters); err != nil {
						return nil, err
					}
					continue
				}
			}
			if err = box.Outbound().Create(static.Context(), box.Router(), box.Logger(), out.Tag, out.Type, parameters); err != nil {
				return nil, err
			}
		}
	}
	outManager, ok := box.Outbound().(interface{ PruneDatabase(map[string]bool) })
	if ok {
		outManager.PruneDatabase(keepOut)
	}
	endManager, ok := box.Endpoint().(interface{ PruneDatabase(map[string]bool) })
	if ok {
		endManager.PruneDatabase(keepEnd)
	}
	active := make([]adapter.Outbound, 0, len(options.Outbounds)+len(options.Endpoints))
	for _, out := range options.Outbounds {
		if current, ok := box.Outbound().Outbound(out.Tag); ok {
			active = append(active, current)
		}
	}
	for _, endpoint := range options.Endpoints {
		if current, ok := box.Endpoint().Get(endpoint.Tag); ok {
			active = append(active, current)
		}
	}
	return active, nil
}
