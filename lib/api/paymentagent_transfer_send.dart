/// Autogenerated from flutter_deriv_api|lib/api/paymentagent_transfer_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'paymentagent_transfer_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PaymentagentTransferRequest extends Request {
  ///
  PaymentagentTransferRequest(
      {this.amount,
      this.currency,
      this.description,
      this.dryRun,
      Map<String, dynamic> passthrough,
      this.paymentagentTransfer,
      int reqId,
      this.transferTo})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory PaymentagentTransferRequest.fromJson(Map<String, dynamic> json) =>
      _$PaymentagentTransferRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$PaymentagentTransferRequestToJson(this);

  // Properties
  /// The amount to transfer.
  num amount;

  /// Currency code.
  String currency;

  /// [Optional] Remarks about the transfer.
  String description;

  /// [Optional] If set to `1`, just do validation.
  int dryRun;

  /// Must be `1`
  int paymentagentTransfer;

  /// The loginid of the recipient account.
  String transferTo;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
