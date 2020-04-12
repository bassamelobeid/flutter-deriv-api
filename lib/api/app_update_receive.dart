/// generated automatically from flutter_deriv_api|lib/api/app_update_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'app_update_receive.g.dart';

/// JSON conversion for 'app_update_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AppUpdateResponse extends Response {
  /// Initialize AppUpdateResponse
  AppUpdateResponse({
    this.appUpdate,
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
  factory AppUpdateResponse.fromJson(Map<String, dynamic> json) =>
      _$AppUpdateResponseFromJson(json);

  // Properties
  /// Information of the updated application.
  final Map<String, dynamic> appUpdate;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$AppUpdateResponseToJson(this);
}
