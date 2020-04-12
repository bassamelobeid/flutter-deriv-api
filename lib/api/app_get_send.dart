/// generated automatically from flutter_deriv_api|lib/api/app_get_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'app_get_send.g.dart';

/// JSON conversion for 'app_get_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AppGetRequest extends Request {
  /// Initialize AppGetRequest
  AppGetRequest({
    this.appGet = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory AppGetRequest.fromJson(Map<String, dynamic> json) =>
      _$AppGetRequestFromJson(json);

  // Properties
  /// Application app_id
  final int appGet;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$AppGetRequestToJson(this);
}
