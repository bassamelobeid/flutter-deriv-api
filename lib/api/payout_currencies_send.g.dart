// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'payout_currencies_send.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PayoutCurrenciesRequest _$PayoutCurrenciesRequestFromJson(
    Map<String, dynamic> json) {
  return PayoutCurrenciesRequest(
    payoutCurrencies: json['payout_currencies'] as int,
    passthrough: json['passthrough'] as Map<String, dynamic>,
    reqId: json['req_id'] as int,
  );
}

Map<String, dynamic> _$PayoutCurrenciesRequestToJson(
        PayoutCurrenciesRequest instance) =>
    <String, dynamic>{
      'passthrough': instance.passthrough,
      'req_id': instance.reqId,
      'payout_currencies': instance.payoutCurrencies,
    };
