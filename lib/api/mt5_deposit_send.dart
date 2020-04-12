/// generated automatically from flutter_deriv_api|lib/api/mt5_deposit_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'mt5_deposit_send.g.dart';

/// JSON conversion for 'mt5_deposit_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5DepositRequest extends Request {
  /// Initialize Mt5DepositRequest
  const Mt5DepositRequest({
    this.amount,
    this.fromBinary,
    this.mt5Deposit = 1,
    this.toMt5,
    int reqId,
    Map<String, dynamic> passthrough,
  }) : super(
          reqId: reqId,
          passthrough: passthrough,
        );

  /// Creates instance from JSON
  factory Mt5DepositRequest.fromJson(Map<String, dynamic> json) =>
      _$Mt5DepositRequestFromJson(json);

  // Properties
  /// Amount to deposit (in the currency of from_binary); min = $1 or an equivalent amount, max = $20000 or an equivalent amount
  final num amount;

  /// Binary account loginid to transfer money from
  final String fromBinary;

  /// Must be `1`
  final int mt5Deposit;

  /// MT5 account login to deposit money to
  final String toMt5;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$Mt5DepositRequestToJson(this);

  /// Creates copy of instance with given parameters
  @override
  Mt5DepositRequest copyWith({
    num amount,
    String fromBinary,
    int mt5Deposit,
    String toMt5,
    int reqId,
    Map<String, dynamic> passthrough,
  }) =>
      Mt5DepositRequest(
        amount: amount ?? this.amount,
        fromBinary: fromBinary ?? this.fromBinary,
        mt5Deposit: mt5Deposit ?? this.mt5Deposit,
        toMt5: toMt5 ?? this.toMt5,
        reqId: reqId ?? this.reqId,
        passthrough: passthrough ?? this.passthrough,
      );

  /// Override equatable class
  @override
  List<Object> get props => null;
}
