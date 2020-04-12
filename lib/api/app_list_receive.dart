/// generated automatically from flutter_deriv_api|lib/api/app_list_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'app_list_receive.g.dart';

/// JSON conversion for 'app_list_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AppListResponse extends Response {
  /// Initialize AppListResponse
  AppListResponse({
    this.appList,
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
  factory AppListResponse.fromJson(Map<String, dynamic> json) =>
      _$AppListResponseFromJson(json);

  // Properties
  /// List of created applications for the authorized account.
  final List<Map<String, dynamic>> appList;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$AppListResponseToJson(this);
}
