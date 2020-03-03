/// Autogenerated from flutter_deriv_api|lib/api/p2p_order_cancel_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'p2p_order_cancel_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pOrderCancelRequest extends Request {
  ///
  P2pOrderCancelRequest(
      {this.id, this.p2pOrderCancel, this.passthrough, this.reqId});

  ///
  factory P2pOrderCancelRequest.fromJson(Map<String, dynamic> json) =>
      _$P2pOrderCancelRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$P2pOrderCancelRequestToJson(this);

  // Properties
  /// The unique identifier for this order.
  String id;

  /// Must be 1
  int p2pOrderCancel;

  /// [Optional] Used to pass data through the websocket, which may be retrieved via the `echo_req` output field.
  Map<String, dynamic> passthrough;

  /// [Optional] Used to map request to response.
  int reqId;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
