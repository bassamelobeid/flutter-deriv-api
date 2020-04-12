/// generated automatically from flutter_deriv_api|lib/api/set_account_currency_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'set_account_currency_receive.g.dart';

/// JSON conversion for 'set_account_currency_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class SetAccountCurrencyResponse extends Response {
  /// Initialize SetAccountCurrencyResponse
  SetAccountCurrencyResponse({
    this.setAccountCurrency,
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
  factory SetAccountCurrencyResponse.fromJson(Map<String, dynamic> json) =>
      _$SetAccountCurrencyResponseFromJson(json);

  // Properties
  /// `1`: success, `0`: no change
  final int setAccountCurrency;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$SetAccountCurrencyResponseToJson(this);
}
