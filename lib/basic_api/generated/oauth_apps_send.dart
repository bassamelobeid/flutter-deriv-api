/// Generated automatically from flutter_deriv_api|lib/basic_api/generated/oauth_apps_send.json
import 'package:json_annotation/json_annotation.dart';

import '../request.dart';

part 'oauth_apps_send.g.dart';

/// JSON conversion for 'oauth_apps_send'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class OauthAppsRequest extends Request {
  /// Initialize OauthAppsRequest
  const OauthAppsRequest({
    this.oauthApps = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          msgType: 'oauth_apps',
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates an instance from JSON
  factory OauthAppsRequest.fromJson(Map<String, dynamic> json) =>
      _$OauthAppsRequestFromJson(json);

  /// Must be `1`
  final int oauthApps;

  /// Converts an instance to JSON
  @override
  Map<String, dynamic> toJson() => _$OauthAppsRequestToJson(this);

  /// Creates a copy of instance with given parameters
  @override
  OauthAppsRequest copyWith({
    int oauthApps,
    Map<String, dynamic> passthrough,
    int reqId,
  }) =>
      OauthAppsRequest(
        oauthApps: oauthApps ?? this.oauthApps,
        passthrough: passthrough ?? this.passthrough,
        reqId: reqId ?? this.reqId,
      );

  /// Override equatable class
  @override
  List<Object> get props => null;
}
