/// Generated automatically from flutter_deriv_api|lib/basic_api/generated/payout_currencies_send.json
import 'package:json_annotation/json_annotation.dart';

import '../request.dart';

part 'payout_currencies_send.g.dart';

/// JSON conversion for 'payout_currencies_send'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class PayoutCurrenciesRequest extends Request {
  /// Initialize PayoutCurrenciesRequest
  const PayoutCurrenciesRequest({
    this.payoutCurrencies = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          msgType: 'payout_currencies',
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates an instance from JSON
  factory PayoutCurrenciesRequest.fromJson(Map<String, dynamic> json) =>
      _$PayoutCurrenciesRequestFromJson(json);

  /// Must be `1`
  final int payoutCurrencies;

  /// Converts an instance to JSON
  @override
  Map<String, dynamic> toJson() => _$PayoutCurrenciesRequestToJson(this);

  /// Creates a copy of instance with given parameters
  @override
  PayoutCurrenciesRequest copyWith({
    int payoutCurrencies,
    Map<String, dynamic> passthrough,
    int reqId,
  }) =>
      PayoutCurrenciesRequest(
        payoutCurrencies: payoutCurrencies ?? this.payoutCurrencies,
        passthrough: passthrough ?? this.passthrough,
        reqId: reqId ?? this.reqId,
      );

  /// Override equatable class
  @override
  List<Object> get props => null;
}
