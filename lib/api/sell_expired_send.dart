/// generated automatically from flutter_deriv_api|lib/api/sell_expired_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'sell_expired_send.g.dart';

/// JSON conversion for 'sell_expired_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class SellExpiredRequest extends Request {
  /// Initialize SellExpiredRequest
  SellExpiredRequest({
    this.sellExpired = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory SellExpiredRequest.fromJson(Map<String, dynamic> json) =>
      _$SellExpiredRequestFromJson(json);

  // Properties
  /// Must be `1`
  final int sellExpired;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$SellExpiredRequestToJson(this);
}
