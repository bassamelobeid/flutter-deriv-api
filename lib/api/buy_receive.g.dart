// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'buy_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BuyResponse _$BuyResponseFromJson(Map<String, dynamic> json) {
  return BuyResponse(
    buy: json['buy'] as Map<String, dynamic>,
    subscription: json['subscription'] as Map<String, dynamic>,
    reqId: json['req_id'] as int,
    echoReq: json['echo_req'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    error: json['error'] as Map<String, dynamic>,
  );
}

Map<String, dynamic> _$BuyResponseToJson(BuyResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'echo_req': instance.echoReq,
      'msg_type': instance.msgType,
      'error': instance.error,
      'buy': instance.buy,
      'subscription': instance.subscription,
    };
