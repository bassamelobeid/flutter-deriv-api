/// generated automatically from flutter_deriv_api|lib/api/p2p_order_cancel_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'p2p_order_cancel_receive.g.dart';

/// JSON conversion for 'p2p_order_cancel_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pOrderCancelResponse extends Response {
  /// Initialize P2pOrderCancelResponse
  P2pOrderCancelResponse({
    this.p2pOrderCancel,
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
  factory P2pOrderCancelResponse.fromJson(Map<String, dynamic> json) =>
      _$P2pOrderCancelResponseFromJson(json);

  // Properties
  /// Cancellation details
  final Map<String, dynamic> p2pOrderCancel;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pOrderCancelResponseToJson(this);
}
