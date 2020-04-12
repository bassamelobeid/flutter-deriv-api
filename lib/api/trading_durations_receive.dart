/// generated automatically from flutter_deriv_api|lib/api/trading_durations_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'trading_durations_receive.g.dart';

/// JSON conversion for 'trading_durations_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class TradingDurationsResponse extends Response {
  /// Initialize TradingDurationsResponse
  TradingDurationsResponse({
    this.tradingDurations,
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
  factory TradingDurationsResponse.fromJson(Map<String, dynamic> json) =>
      _$TradingDurationsResponseFromJson(json);

  // Properties
  /// List of underlyings by their display name and symbol followed by their available contract types and trading duration boundaries.
  final List<Map<String, dynamic>> tradingDurations;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$TradingDurationsResponseToJson(this);
}
