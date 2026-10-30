import 'dart:isolate';
import 'dart:typed_data';

import 'package:grpc/grpc.dart' hide Response;
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';

/// Keep protobuf decoding of large outbound snapshots off the UI isolate.
class ResponsiveCoreClient extends CoreClient {
  ResponsiveCoreClient(super.channel, {super.options, super.interceptors, ClientChannel? controlChannel})
    : _control = controlChannel == null
          ? null
          : CoreClient(controlChannel, options: options, interceptors: interceptors);

  final CoreClient? _control;

  // A paused/large outbound stream must not hold up Start, Stop or settings on
  // the same HTTP/2 connection. Each platform supplies a separate control lane.
  @override
  ResponseFuture<R> $createUnaryCall<Q, R>(ClientMethod<Q, R> method, Q request, {CallOptions? options}) =>
      _control?.$createUnaryCall(method, request, options: options) ??
      super.$createUnaryCall(method, request, options: options);

  @override
  ResponseStream<CoreInfoResponse> coreInfoListener(Empty request, {CallOptions? options}) =>
      _control?.coreInfoListener(request, options: options) ?? super.coreInfoListener(request, options: options);

  static final _rawOutbounds = ClientMethod<Empty, Uint8List>(
    '/hcore.Core/OutboundsInfo',
    (request) => request.writeToBuffer(),
    (bytes) => bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
  );

  static final _rawParse = ClientMethod<ParseRequest, Uint8List>(
    '/hcore.Core/Parse',
    (request) => request.writeToBuffer(),
    (bytes) => bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
  );

  Future<ParseResponse> parseForValidation(ParseRequest request) async {
    final bytes = await $createUnaryCall(_rawParse, request);
    return decodeValidationResponse(bytes);
  }

  ResponseStream<Uint8List> rawOutbounds() => $createStreamingCall(_rawOutbounds, Stream.value(Empty()));

  static final _availability = ClientMethod<UrlTestRequest, Response>(
    '/proxyyou.Availability/Check',
    (request) => request.writeToBuffer(),
    Response.fromBuffer,
  );

  static final _verification = ClientMethod<UrlTestRequest, Response>(
    '/proxyyou.Availability/Verify',
    (request) => request.writeToBuffer(),
    Response.fromBuffer,
  );

  ResponseFuture<Response> completeVerification(String tag, String ticket, {required bool passed}) => $createUnaryCall(
    ClientMethod<SelectOutboundRequest, Response>(
      '/proxyyou.Availability/${passed ? 'Passed' : 'Failed'}',
      (request) => request.writeToBuffer(),
      Response.fromBuffer,
    ),
    SelectOutboundRequest(groupTag: ticket, outboundTag: tag),
    options: CallOptions(timeout: const Duration(seconds: 10)),
  );

  ResponseFuture<Response> verifyAvailability(String tag) => $createUnaryCall(
    _verification,
    UrlTestRequest(tag: tag),
    options: CallOptions(timeout: const Duration(seconds: 24)),
  );

  ResponseFuture<Response> checkAvailability(String tag) => $createUnaryCall(
    _availability,
    UrlTestRequest(tag: tag),
    options: CallOptions(timeout: const Duration(seconds: 16)),
  );
}

Future<ParseResponse> decodeValidationResponse(Uint8List bytes) => Isolate.run(() {
  final result = ParseResponse.fromBuffer(bytes);
  // The core has already written content to configPath. Import needs only status.
  return ParseResponse(responseCode: result.responseCode, message: result.message);
});

const youtubeTestUrl = 'https://www.youtube.com/generate_204';
const concurrentServerTests = 20;
