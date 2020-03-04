/// Autogenerated from flutter_deriv_api|lib/api/paymentagent_transfer_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'paymentagent_transfer_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PaymentagentTransferResponse extends Response {
  ///
  PaymentagentTransferResponse(
      {this.clientToFullName,
      this.clientToLoginid,
      this.paymentagentTransfer,
      this.transactionId,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory PaymentagentTransferResponse.fromJson(Map<String, dynamic> json) =>
      _$PaymentagentTransferResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$PaymentagentTransferResponseToJson(this);

  // Properties
  /// The `transfer_to` client full name
  String clientToFullName;

  /// The `transfer_to` client loginid
  String clientToLoginid;

  /// If set to `1`, transfer success. If set to `2`, dry-run success.
  int paymentagentTransfer;

  /// Reference ID of transfer performed
  int transactionId;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
