/// Autogenerated from flutter_deriv_api|lib/api/p2p_order_info_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'p2p_order_info_send.g.dart';

/// JSON conversion for 'p2p_order_info_send'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class P2pOrderInfoRequest extends Request {
  /// Initialize P2pOrderInfoRequest
  P2pOrderInfoRequest(
      {this.id,
      this.p2pOrderInfo = 1,
      this.subscribe,
      int reqId,
      Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  /// Factory constructor to initialize from JSON
  factory P2pOrderInfoRequest.fromJson(Map<String, dynamic> json) =>
      _$P2pOrderInfoRequestFromJson(json);

  // Properties
  /// The unique identifier for the order.
  String id;

  /// Must be 1
  int p2pOrderInfo;

  /// [Optional] If set to 1, will send updates whenever there is an update to order
  int subscribe;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pOrderInfoRequestToJson(this);
}
