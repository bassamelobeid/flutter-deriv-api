// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'mt5_password_change_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Mt5PasswordChangeResponse _$Mt5PasswordChangeResponseFromJson(
    Map<String, dynamic> json) {
  return Mt5PasswordChangeResponse(
    echoReq: json['echo_req'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    mt5PasswordChange: json['mt5_password_change'] as int,
    reqId: json['req_id'] as int,
  )..error = json['error'] as Map<String, dynamic>;
}

Map<String, dynamic> _$Mt5PasswordChangeResponseToJson(
        Mt5PasswordChangeResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'echo_req': instance.echoReq,
      'msg_type': instance.msgType,
      'error': instance.error,
      'mt5_password_change': instance.mt5PasswordChange,
    };
