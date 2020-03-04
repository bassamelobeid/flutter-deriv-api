// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'paymentagent_transfer_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PaymentagentTransferResponse _$PaymentagentTransferResponseFromJson(
    Map<String, dynamic> json) {
  return PaymentagentTransferResponse(
    clientToFullName: json['client_to_full_name'] as String,
    clientToLoginid: json['client_to_loginid'] as String,
    paymentagentTransfer: json['paymentagent_transfer'] as int,
    transactionId: json['transaction_id'] as int,
    reqId: json['req_id'] as int,
    echoReq: json['echo_req'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    error: json['error'] as Map<String, dynamic>,
  );
}

Map<String, dynamic> _$PaymentagentTransferResponseToJson(
        PaymentagentTransferResponse instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'echo_req': instance.echoReq,
      'msg_type': instance.msgType,
      'error': instance.error,
      'client_to_full_name': instance.clientToFullName,
      'client_to_loginid': instance.clientToLoginid,
      'paymentagent_transfer': instance.paymentagentTransfer,
      'transaction_id': instance.transactionId,
    };
