// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'service_token_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ServiceTokenResponse _$ServiceTokenResponseFromJson(Map<String, dynamic> json) {
  return ServiceTokenResponse(
    serviceToken: json['service_token'] as Map<String, dynamic>,
    reqId: json['req_id'] as int,
    echoReq: json['echo_req'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    error: json['error'] as Map<String, dynamic>,
  );
}

Map<String, dynamic> _$ServiceTokenResponseToJson(
        ServiceTokenResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'echo_req': instance.echoReq,
      'msg_type': instance.msgType,
      'error': instance.error,
      'service_token': instance.serviceToken,
    };
