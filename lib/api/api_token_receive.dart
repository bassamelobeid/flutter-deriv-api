/// generated automatically from flutter_deriv_api|lib/api/api_token_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'api_token_receive.g.dart';

/// JSON conversion for 'api_token_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ApiTokenResponse extends Response {
  /// Initialize ApiTokenResponse
  ApiTokenResponse({
    this.apiToken,
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
  factory ApiTokenResponse.fromJson(Map<String, dynamic> json) =>
      _$ApiTokenResponseFromJson(json);

  // Properties
  /// Contains the result of API token according to the type of request.
  final Map<String, dynamic> apiToken;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$ApiTokenResponseToJson(this);
}
