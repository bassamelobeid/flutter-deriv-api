/// generated automatically from flutter_deriv_api|lib/api/get_settings_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'get_settings_receive.g.dart';

/// JSON conversion for 'get_settings_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class GetSettingsResponse extends Response {
  /// Initialize GetSettingsResponse
  GetSettingsResponse({
    this.getSettings,
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
  factory GetSettingsResponse.fromJson(Map<String, dynamic> json) =>
      _$GetSettingsResponseFromJson(json);

  // Properties
  /// User information and settings.
  final Map<String, dynamic> getSettings;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$GetSettingsResponseToJson(this);
}
