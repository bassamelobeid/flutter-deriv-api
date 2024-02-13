/// Generated automatically from flutter_deriv_api|lib/basic_api/generated/p2p_advertiser_create_receive.json.

// ignore_for_file: always_put_required_named_parameters_first

import '../response.dart';

/// P2p advertiser create receive class.
class P2pAdvertiserCreateReceive extends Response {
  /// Initialize P2pAdvertiserCreateReceive.
  const P2pAdvertiserCreateReceive({
    this.p2pAdvertiserCreate,
    this.subscription,
    super.echoReq,
    super.error,
    super.msgType,
    super.reqId,
  });

  /// Creates an instance from JSON.
  factory P2pAdvertiserCreateReceive.fromJson(Map<String, dynamic> json) =>
      P2pAdvertiserCreateReceive(
        p2pAdvertiserCreate:
            json['p2p_advertiser_create'] as Map<String, dynamic>?,
        subscription: json['subscription'] as Map<String, dynamic>?,
        echoReq: json['echo_req'] as Map<String, dynamic>?,
        error: json['error'] as Map<String, dynamic>?,
        msgType: json['msg_type'] as String?,
        reqId: json['req_id'] as int?,
      );

  /// P2P advertiser information.
  final Map<String, dynamic>? p2pAdvertiserCreate;

  /// For subscription requests only.
  final Map<String, dynamic>? subscription;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'p2p_advertiser_create': p2pAdvertiserCreate,
        'subscription': subscription,
        'echo_req': echoReq,
        'error': error,
        'msg_type': msgType,
        'req_id': reqId,
      };

  /// Creates a copy of instance with given parameters
  @override
  P2pAdvertiserCreateReceive copyWith({
    Map<String, dynamic>? p2pAdvertiserCreate,
    Map<String, dynamic>? subscription,
    Map<String, dynamic>? echoReq,
    Map<String, dynamic>? error,
    String? msgType,
    int? reqId,
  }) =>
      P2pAdvertiserCreateReceive(
        p2pAdvertiserCreate: p2pAdvertiserCreate ?? this.p2pAdvertiserCreate,
        subscription: subscription ?? this.subscription,
        echoReq: echoReq ?? this.echoReq,
        error: error ?? this.error,
        msgType: msgType ?? this.msgType,
        reqId: reqId ?? this.reqId,
      );

  /// Override equatable class.
  @override
  List<Object?> get props => <Object?>[];
}
