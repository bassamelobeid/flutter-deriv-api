/// generated automatically from flutter_deriv_api|lib/api/mt5_new_account_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'mt5_new_account_receive.g.dart';

/// JSON conversion for 'mt5_new_account_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5NewAccountResponse extends Response {
  /// Initialize Mt5NewAccountResponse
  Mt5NewAccountResponse({
    this.mt5NewAccount,
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
  factory Mt5NewAccountResponse.fromJson(Map<String, dynamic> json) =>
      _$Mt5NewAccountResponseFromJson(json);

  // Properties
  /// New MT5 account details
  final Map<String, dynamic> mt5NewAccount;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$Mt5NewAccountResponseToJson(this);
}
