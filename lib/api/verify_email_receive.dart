/// generated automatically from flutter_deriv_api|lib/api/verify_email_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'verify_email_receive.g.dart';

/// JSON conversion for 'verify_email_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class VerifyEmailResponse extends Response {
  /// Initialize VerifyEmailResponse
  VerifyEmailResponse({
    this.verifyEmail,
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
  factory VerifyEmailResponse.fromJson(Map<String, dynamic> json) =>
      _$VerifyEmailResponseFromJson(json);

  // Properties
  /// 1 for success (secure code has been sent to the email address)
  final int verifyEmail;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$VerifyEmailResponseToJson(this);
}
