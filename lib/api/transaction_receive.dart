/// generated automatically from flutter_deriv_api|lib/api/transaction_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'transaction_receive.g.dart';

/// JSON conversion for 'transaction_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class TransactionResponse extends Response {
  /// Initialize TransactionResponse
  TransactionResponse({
    this.subscription,
    this.transaction,
    Map<String, dynamic> echoReq,
    Map<String, dynamic> error,
    String msgType,
    int reqId,
  }) : super(
          echoReq: echoReq,
          error: error,
          msgType: msgType,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory TransactionResponse.fromJson(Map<String, dynamic> json) =>
      _$TransactionResponseFromJson(json);

  // Properties
  /// For subscription requests only.
  final Map<String, dynamic> subscription;

  /// Realtime stream of user transaction updates.
  final Map<String, dynamic> transaction;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$TransactionResponseToJson(this);
}
