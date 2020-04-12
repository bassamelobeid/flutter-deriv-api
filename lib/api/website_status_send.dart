/// generated automatically from flutter_deriv_api|lib/api/website_status_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'website_status_send.g.dart';

/// JSON conversion for 'website_status_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class WebsiteStatusRequest extends Request {
  /// Initialize WebsiteStatusRequest
  WebsiteStatusRequest({
    this.subscribe,
    this.websiteStatus = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory WebsiteStatusRequest.fromJson(Map<String, dynamic> json) =>
      _$WebsiteStatusRequestFromJson(json);

  // Properties
  /// [Optional] `1` to stream the server/website status updates.
  final int subscribe;

  /// Must be `1`
  final int websiteStatus;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$WebsiteStatusRequestToJson(this);
}
