/// generated automatically from flutter_deriv_api|lib/api/mt5_get_settings_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'mt5_get_settings_receive.g.dart';

/// JSON conversion for 'mt5_get_settings_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class Mt5GetSettingsResponse extends Response {
  /// Initialize Mt5GetSettingsResponse
  Mt5GetSettingsResponse({
    this.mt5GetSettings,
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
  factory Mt5GetSettingsResponse.fromJson(Map<String, dynamic> json) =>
      _$Mt5GetSettingsResponseFromJson(json);

  // Properties
  /// MT5 user account details
  final Map<String, dynamic> mt5GetSettings;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$Mt5GetSettingsResponseToJson(this);
}
