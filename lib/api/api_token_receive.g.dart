// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'api_token_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ApiTokenResponse _$ApiTokenResponseFromJson(Map<String, dynamic> json) {
  return ApiTokenResponse(
    apiToken: json['api_token'] as Map<String, dynamic>,
    reqId: json['req_id'] as int,
    echoReq: json['echo_req'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    error: json['error'] as Map<String, dynamic>,
  );
}

Map<String, dynamic> _$ApiTokenResponseToJson(ApiTokenResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'echo_req': instance.echoReq,
      'msg_type': instance.msgType,
      'error': instance.error,
      'api_token': instance.apiToken,
    };
