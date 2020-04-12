/// generated automatically from flutter_deriv_api|lib/api/mt5_deposit_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'mt5_deposit_receive.g.dart';

/// JSON conversion for 'mt5_deposit_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5DepositResponse extends Response {
  /// Initialize Mt5DepositResponse
  Mt5DepositResponse({
    this.binaryTransactionId,
    this.mt5Deposit,
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
  factory Mt5DepositResponse.fromJson(Map<String, dynamic> json) =>
      _$Mt5DepositResponseFromJson(json);

  // Properties
  /// Withdrawal reference ID of Binary account
  final int binaryTransactionId;

  /// 1 on success
  final int mt5Deposit;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$Mt5DepositResponseToJson(this);
}
