/// generated automatically from flutter_deriv_api|lib/api/exchange_rates_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'exchange_rates_receive.g.dart';

/// JSON conversion for 'exchange_rates_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ExchangeRatesResponse extends Response {
  /// Initialize ExchangeRatesResponse
  ExchangeRatesResponse({
    this.exchangeRates,
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
  factory ExchangeRatesResponse.fromJson(Map<String, dynamic> json) =>
      _$ExchangeRatesResponseFromJson(json);

  // Properties
  /// Exchange rate values from base to all other currencies
  final Map<String, dynamic> exchangeRates;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$ExchangeRatesResponseToJson(this);
}
