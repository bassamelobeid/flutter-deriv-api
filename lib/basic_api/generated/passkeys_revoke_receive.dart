/// Generated automatically from flutter_deriv_api|lib/basic_api/generated/passkeys_revoke_receive.json.

// ignore_for_file: always_put_required_named_parameters_first

import '../response.dart';

/// Passkeys revoke receive class.
class PasskeysRevokeReceive extends Response {
  /// Initialize PasskeysRevokeReceive.
  const PasskeysRevokeReceive({
    this.passkeysRevoke,
    super.echoReq,
    super.error,
    super.msgType,
    super.reqId,
  });

  /// Creates an instance from JSON.
  factory PasskeysRevokeReceive.fromJson(Map<String, dynamic> json) =>
      PasskeysRevokeReceive(
        passkeysRevoke: json['passkeys_revoke'] as int?,
        echoReq: json['echo_req'] as Map<String, dynamic>?,
        error: json['error'] as Map<String, dynamic>?,
        msgType: json['msg_type'] as String?,
        reqId: json['req_id'] as int?,
      );

  /// 1 on success
  final int? passkeysRevoke;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'passkeys_revoke': passkeysRevoke,
        'echo_req': echoReq,
        'error': error,
        'msg_type': msgType,
        'req_id': reqId,
      };

  /// Creates a copy of instance with given parameters
  @override
  PasskeysRevokeReceive copyWith({
    int? passkeysRevoke,
    Map<String, dynamic>? echoReq,
    Map<String, dynamic>? error,
    String? msgType,
    int? reqId,
  }) =>
      PasskeysRevokeReceive(
        passkeysRevoke: passkeysRevoke ?? this.passkeysRevoke,
        echoReq: echoReq ?? this.echoReq,
        error: error ?? this.error,
        msgType: msgType ?? this.msgType,
        reqId: reqId ?? this.reqId,
      );

  /// Override equatable class.
  @override
  List<Object?> get props => <Object?>[];
}
