// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ticks_history_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TicksHistoryResponse _$TicksHistoryResponseFromJson(Map<String, dynamic> json) {
  return TicksHistoryResponse(
    candles: (json['candles'] as List)
        .map((e) => e as Map<String, dynamic>)
        .toList(),
    echoReq: json['echo_req'] as Map<String, dynamic>,
    history: json['history'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    pipSize: json['pip_size'] as num,
    reqId: json['req_id'] as int,
    subscription: json['subscription'] as Map<String, dynamic>,
  )..error = json['error'] as Map<String, dynamic>;
}

Map<String, dynamic> _$TicksHistoryResponseToJson(
        TicksHistoryResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'echo_req': instance.echoReq,
      'msg_type': instance.msgType,
      'error': instance.error,
      'candles': instance.candles,
      'history': instance.history,
      'pip_size': instance.pipSize,
      'subscription': instance.subscription,
    };
