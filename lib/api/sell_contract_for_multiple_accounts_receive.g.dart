// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sell_contract_for_multiple_accounts_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SellContractForMultipleAccountsResponse
    _$SellContractForMultipleAccountsResponseFromJson(
        Map<String, dynamic> json) {
  return SellContractForMultipleAccountsResponse(
    echoReq: json['echo_req'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    reqId: json['req_id'] as int,
    sellContractForMultipleAccounts:
        json['sell_contract_for_multiple_accounts'] as Map<String, dynamic>,
  )..error = json['error'] as Map<String, dynamic>;
}

Map<String, dynamic> _$SellContractForMultipleAccountsResponseToJson(
        SellContractForMultipleAccountsResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'echo_req': instance.echoReq,
      'msg_type': instance.msgType,
      'error': instance.error,
      'sell_contract_for_multiple_accounts':
          instance.sellContractForMultipleAccounts,
    };
