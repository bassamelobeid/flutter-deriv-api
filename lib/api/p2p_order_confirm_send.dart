/// generated automatically from flutter_deriv_api|lib/api/p2p_order_confirm_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'p2p_order_confirm_send.g.dart';

/// JSON conversion for 'p2p_order_confirm_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pOrderConfirmRequest extends Request {
  /// Initialize P2pOrderConfirmRequest
  P2pOrderConfirmRequest({
    this.id,
    this.p2pOrderConfirm = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory P2pOrderConfirmRequest.fromJson(Map<String, dynamic> json) =>
      _$P2pOrderConfirmRequestFromJson(json);

  // Properties
  /// The unique identifier for this order.
  final String id;

  /// Must be 1
  final int p2pOrderConfirm;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pOrderConfirmRequestToJson(this);
}
