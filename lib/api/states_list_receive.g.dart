// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'states_list_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

StatesListResponse _$StatesListResponseFromJson(Map<String, dynamic> json) {
  return StatesListResponse(
    statesList: (json['states_list'] as List)
        .map((e) => e as Map<String, dynamic>)
        .toList(),
    reqId: json['req_id'] as int,
    msgType: json['msg_type'] as String,
    echoReq: json['echo_req'] as Map<String, dynamic>,
    error: json['error'] as Map<String, dynamic>,
  );
}

Map<String, dynamic> _$StatesListResponseToJson(StatesListResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'msg_type': instance.msgType,
      'echo_req': instance.echoReq,
      'error': instance.error,
      'states_list': instance.statesList,
    };
