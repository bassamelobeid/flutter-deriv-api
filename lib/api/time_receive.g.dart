// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'time_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TimeResponse _$TimeResponseFromJson(Map<String, dynamic> json) {
  return TimeResponse(
    time: json['time'] as int,
    reqId: json['req_id'] as int,
    echoReq: json['echo_req'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    error: json['error'] as Map<String, dynamic>,
  );
}

Map<String, dynamic> _$TimeResponseToJson(TimeResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'echo_req': instance.echoReq,
      'msg_type': instance.msgType,
      'error': instance.error,
      'time': instance.time,
    };
