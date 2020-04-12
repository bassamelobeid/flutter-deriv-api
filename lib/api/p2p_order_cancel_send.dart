/// generated automatically from flutter_deriv_api|lib/api/p2p_order_cancel_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'p2p_order_cancel_send.g.dart';

/// JSON conversion for 'p2p_order_cancel_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pOrderCancelRequest extends Request {
  /// Initialize P2pOrderCancelRequest
  P2pOrderCancelRequest({
    this.id,
    this.p2pOrderCancel = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory P2pOrderCancelRequest.fromJson(Map<String, dynamic> json) =>
      _$P2pOrderCancelRequestFromJson(json);

  // Properties
  /// The unique identifier for this order.
  final String id;

  /// Must be 1
  final int p2pOrderCancel;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pOrderCancelRequestToJson(this);
}
