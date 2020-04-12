/// generated automatically from flutter_deriv_api|lib/api/app_get_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'app_get_receive.g.dart';

/// JSON conversion for 'app_get_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AppGetResponse extends Response {
  /// Initialize AppGetResponse
  AppGetResponse({
    this.appGet,
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
  factory AppGetResponse.fromJson(Map<String, dynamic> json) =>
      _$AppGetResponseFromJson(json);

  // Properties
  /// The information of the requested application.
  final Map<String, dynamic> appGet;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$AppGetResponseToJson(this);
}
