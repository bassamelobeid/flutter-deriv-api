/// generated automatically from flutter_deriv_api|lib/api/buy_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'buy_receive.g.dart';

/// JSON conversion for 'buy_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class BuyResponse extends Response {
  /// Initialize BuyResponse
  BuyResponse({
    this.buy,
    this.subscription,
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
  factory BuyResponse.fromJson(Map<String, dynamic> json) =>
      _$BuyResponseFromJson(json);

  // Properties
  /// Receipt confirmation for the purchase
  final Map<String, dynamic> buy;

  /// For subscription requests only.
  final Map<String, dynamic> subscription;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$BuyResponseToJson(this);
}
