/// Autogenerated from flutter_deriv_api|lib/api/transaction_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'transaction_receive.g.dart';

/// JSON conversion for 'transaction_receive'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class TransactionResponse extends Response {
  /// Initialize TransactionResponse
  TransactionResponse(
      {this.subscription,
      this.transaction,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory TransactionResponse.fromJson(Map<String, dynamic> json) =>
      _$TransactionResponseFromJson(json);

  // Properties
  /// For subscription requests only
  Map<String, dynamic> subscription;

  /// Realtime stream of user transaction updates.
  Map<String, dynamic> transaction;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$TransactionResponseToJson(this);
}
