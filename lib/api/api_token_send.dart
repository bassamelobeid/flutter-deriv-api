/// generated automatically from flutter_deriv_api|lib/api/api_token_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'api_token_send.g.dart';

/// JSON conversion for 'api_token_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ApiTokenRequest extends Request {
  /// Initialize ApiTokenRequest
  ApiTokenRequest({
    this.apiToken = 1,
    this.deleteToken,
    this.newToken,
    this.newTokenScopes,
    this.validForCurrentIpOnly,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory ApiTokenRequest.fromJson(Map<String, dynamic> json) =>
      _$ApiTokenRequestFromJson(json);

  // Properties
  /// Must be `1`
  final int apiToken;

  /// [Optional] The token to remove.
  final String deleteToken;

  /// [Optional] The name of the created token.
  final String newToken;

  /// [Optional] List of permission scopes to provide with the token.
  final List<String> newTokenScopes;

  /// [Optional] If you set this parameter during token creation, then the token created will only work for the IP address that was used to create the token
  final int validForCurrentIpOnly;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$ApiTokenRequestToJson(this);
}
