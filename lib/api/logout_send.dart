/// generated automatically from flutter_deriv_api|lib/api/logout_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'logout_send.g.dart';

/// JSON conversion for 'logout_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class LogoutRequest extends Request {
  /// Initialize LogoutRequest
  LogoutRequest({
    this.logout = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory LogoutRequest.fromJson(Map<String, dynamic> json) =>
      _$LogoutRequestFromJson(json);

  // Properties
  /// Must be `1`
  final int logout;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$LogoutRequestToJson(this);
}
