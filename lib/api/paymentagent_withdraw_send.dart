/// generated automatically from flutter_deriv_api|lib/api/paymentagent_withdraw_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'paymentagent_withdraw_send.g.dart';

/// JSON conversion for 'paymentagent_withdraw_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PaymentagentWithdrawRequest extends Request {
  /// Initialize PaymentagentWithdrawRequest
  PaymentagentWithdrawRequest({
    this.amount,
    this.currency,
    this.description,
    this.dryRun,
    this.paymentagentLoginid,
    this.paymentagentWithdraw = 1,
    this.verificationCode,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory PaymentagentWithdrawRequest.fromJson(Map<String, dynamic> json) =>
      _$PaymentagentWithdrawRequestFromJson(json);

  // Properties
  /// The amount to withdraw to the payment agent.
  final num amount;

  /// The currency code.
  final String currency;

  /// [Optional] Remarks about the withdraw. Only letters, numbers, space, period, comma, - ' are allowed.
  final String description;

  /// [Optional] If set to 1, just do validation.
  final int dryRun;

  /// The payment agent loginid received from the `paymentagent_list` call.
  final String paymentagentLoginid;

  /// Must be `1`
  final int paymentagentWithdraw;

  /// Email verification code (received from a `verify_email` call, which must be done first)
  final String verificationCode;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$PaymentagentWithdrawRequestToJson(this);
}
