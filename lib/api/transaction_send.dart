/// Autogenerated from flutter_deriv_api|lib/api/transaction_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'transaction_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class TransactionRequest extends Request {
  ///
  TransactionRequest(
      {Map<String, dynamic> passthrough,
      int reqId,
      this.subscribe,
      this.transaction})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory TransactionRequest.fromJson(Map<String, dynamic> json) =>
      _$TransactionRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$TransactionRequestToJson(this);

  // Properties

  /// If set to 1, will send updates whenever there is an update to transactions. If not to 1 then it will not return any records.
  int subscribe;

  /// Must be `1`
  int transaction;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
