/// generated automatically from flutter_deriv_api|lib/api/paymentagent_withdraw_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'paymentagent_withdraw_receive.g.dart';

/// JSON conversion for 'paymentagent_withdraw_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PaymentagentWithdrawResponse extends Response {
  /// Initialize PaymentagentWithdrawResponse
  PaymentagentWithdrawResponse({
    this.paymentagentName,
    this.paymentagentWithdraw,
    this.transactionId,
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
  factory PaymentagentWithdrawResponse.fromJson(Map<String, dynamic> json) =>
      _$PaymentagentWithdrawResponseFromJson(json);

  // Properties
  /// Payment agent name.
  final String paymentagentName;

  /// If set to `1`, withdrawal success. If set to `2`, dry-run success.
  final int paymentagentWithdraw;

  /// Reference ID of withdrawal performed.
  final int transactionId;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$PaymentagentWithdrawResponseToJson(this);
}
