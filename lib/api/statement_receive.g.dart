// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'statement_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

StatementResponse _$StatementResponseFromJson(Map<String, dynamic> json) {
  return StatementResponse(
    echoReq: json['echo_req'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    reqId: json['req_id'] as int,
    statement: json['statement'] as Map<String, dynamic>,
  )..error = json['error'] as Map<String, dynamic>;
}

Map<String, dynamic> _$StatementResponseToJson(StatementResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'echo_req': instance.echoReq,
      'msg_type': instance.msgType,
      'error': instance.error,
      'statement': instance.statement,
    };
