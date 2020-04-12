/// generated automatically from flutter_deriv_api|lib/api/mt5_password_check_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'mt5_password_check_receive.g.dart';

/// JSON conversion for 'mt5_password_check_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5PasswordCheckResponse extends Response {
  /// Initialize Mt5PasswordCheckResponse
  Mt5PasswordCheckResponse({
    this.mt5PasswordCheck,
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
  factory Mt5PasswordCheckResponse.fromJson(Map<String, dynamic> json) =>
      _$Mt5PasswordCheckResponseFromJson(json);

  // Properties
  /// `1` on success
  final int mt5PasswordCheck;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$Mt5PasswordCheckResponseToJson(this);
}
