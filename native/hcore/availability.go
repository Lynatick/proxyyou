package hcore

import (
	"context"
	"encoding/json"

	"github.com/hiddify/hiddify-core/v2/config"
	"github.com/hiddify/hiddify-core/v2/hcommon"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
	G "github.com/sagernet/sing-box/protocol/group"
	B "github.com/sagernet/sing-box/protocol/group/balancer"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type availabilityServer interface {
	Check(context.Context, *UrlTestRequest) (*hcommon.Response, error)
	Verify(context.Context, *UrlTestRequest) (*hcommon.Response, error)
	Complete(context.Context, *SelectOutboundRequest, bool) (*hcommon.Response, error)
}
type availabilityService struct{}

func (*availabilityService) Check(ctx context.Context, in *UrlTestRequest) (*hcommon.Response, error) {
	return runAvailability(ctx, in, false)
}
func (*availabilityService) Verify(ctx context.Context, in *UrlTestRequest) (*hcommon.Response, error) {
	return runAvailability(ctx, in, true)
}
func runAvailability(ctx context.Context, in *UrlTestRequest, sequential bool) (*hcommon.Response, error) {
	static.lock.Lock()
	instanceCtx := static.Context()
	var monitor *monitoring.OutboundMonitoring
	if instanceCtx != nil {
		monitor = monitoring.Get(instanceCtx)
	}
	static.lock.Unlock()
	if monitor == nil {
		return nil, status.Error(codes.FailedPrecondition, "core is not running")
	}
	var report monitoring.AvailabilityReport
	var err error
	if sequential {
		report, err = monitor.VerifyAvailability(ctx, in.Tag)
	} else {
		report, err = monitor.CheckAvailability(ctx, in.Tag)
	}
	if err != nil {
		if ctx.Err() != nil || instanceCtx.Err() != nil {
			return nil, status.Error(codes.Canceled, "availability check canceled")
		}
		return nil, status.Error(codes.FailedPrecondition, err.Error())
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		return nil, status.Error(codes.Internal, "availability result encoding failed")
	}
	return &hcommon.Response{Code: hcommon.ResponseCode_OK, Message: string(encoded)}, nil
}

// This extension reuses the existing tag request / response wire messages, so
// upstream generated Core clients and mobile bindings need no regeneration.
func registerAvailabilityServer(server *grpc.Server) {
	server.RegisterService(&grpc.ServiceDesc{
		ServiceName: "proxyyou.Availability", HandlerType: (*availabilityServer)(nil),
		Methods: []grpc.MethodDesc{verificationResultMethod("Passed", true), verificationResultMethod("Failed", false), availabilityMethod("Verify"), availabilityMethod("Check")},
	}, &availabilityService{})
}

func availabilityMethod(method string) grpc.MethodDesc {
	return grpc.MethodDesc{MethodName: method, Handler: func(srv interface{}, ctx context.Context, decode func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
		request := new(UrlTestRequest)
		if err := decode(request); err != nil {
			return nil, err
		}
		handler := func(ctx context.Context, req interface{}) (interface{}, error) {
			if method == "Verify" {
				return srv.(availabilityServer).Verify(ctx, req.(*UrlTestRequest))
			}
			return srv.(availabilityServer).Check(ctx, req.(*UrlTestRequest))
		}
		if interceptor == nil {
			return handler(ctx, request)
		}
		return interceptor(ctx, request, &grpc.UnaryServerInfo{Server: srv, FullMethod: "/proxyyou.Availability/" + method}, handler)
	}}
}

func (*availabilityService) Complete(ctx context.Context, in *SelectOutboundRequest, success bool) (*hcommon.Response, error) {
	static.lock.Lock()
	defer static.lock.Unlock()
	instanceCtx := static.Context()
	box := static.Box()
	if instanceCtx == nil || box == nil || instanceCtx.Err() != nil || ctx.Err() != nil {
		return nil, status.Error(codes.Canceled, "verification session ended")
	}
	monitor := monitoring.Get(instanceCtx)
	if monitor == nil || !monitor.CompleteVerification(in.OutboundTag, in.GroupTag, success) {
		return nil, status.Error(codes.Canceled, "stale verification result")
	}
	next := ""
	if !success {
		out, ok := box.Outbound().Outbound(config.OutboundSelectTag)
		if ok {
			selector, selectable := out.(*G.Selector)
			if selectable && currentVerificationTag() == in.OutboundTag {
				selected := selector.Now()
				mode, _ := box.Outbound().Outbound(selected)
				if automatic, automaticMode := mode.(*B.Balancer); automaticMode {
					next = automatic.SelectAfterVerificationFailure()
				} else {
					next = monitor.NextVerificationTag(in.OutboundTag)
					if next != "" && !selector.SelectOutbound(next) {
						next = ""
					}
				}
			}
		}
		monitor.SelectionChanged(config.OutboundSelectTag)
	}
	return &hcommon.Response{Code: hcommon.ResponseCode_OK, Message: next}, nil
}
func verificationResultMethod(name string, success bool) grpc.MethodDesc {
	return grpc.MethodDesc{MethodName: name, Handler: func(srv interface{}, ctx context.Context, decode func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
		request := new(SelectOutboundRequest)
		if err := decode(request); err != nil {
			return nil, err
		}
		handler := func(ctx context.Context, request interface{}) (interface{}, error) {
			return srv.(availabilityServer).Complete(ctx, request.(*SelectOutboundRequest), success)
		}
		if interceptor == nil {
			return handler(ctx, request)
		}
		return interceptor(ctx, request, &grpc.UnaryServerInfo{Server: srv, FullMethod: "/proxyyou.Availability/" + name}, handler)
	}}
}

// Resolve every group on the selected path, rather than mistaking balance/lowest
// for the concrete server whose verification failed.
func currentVerificationTag() string {
	box := static.Box()
	if box == nil {
		return ""
	}
	tag := config.OutboundSelectTag
	seen := make(map[string]bool)
	for !seen[tag] {
		seen[tag] = true
		out, ok := box.Outbound().Outbound(tag)
		if !ok {
			out, ok = box.Endpoint().Get(tag)
		}
		if !ok {
			return ""
		}
		group, isGroup := out.(adapter.OutboundGroup)
		if !isGroup {
			return tag
		}
		tag = group.Now()
		if tag == "" {
			return ""
		}
	}
	return ""
}
