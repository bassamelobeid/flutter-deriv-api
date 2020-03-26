/// Autogenerated from flutter_deriv_api|lib/api/p2p_order_list_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'p2p_order_list_send.g.dart';

/// JSON conversion for 'p2p_order_list_send'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class P2pOrderListRequest extends Request {
  /// Initialize P2pOrderListRequest
  P2pOrderListRequest(
      {this.active,
      this.advertId,
      this.limit,
      this.offset,
      this.p2pOrderList = 1,
      this.subscribe,
      int reqId,
      Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  /// Factory constructor to initialize from JSON
  factory P2pOrderListRequest.fromJson(Map<String, dynamic> json) =>
      _$P2pOrderListRequestFromJson(json);

  // Properties
  /// [Optional] Should be 1 to list active, 0 to list inactive (historical).
  num active;

  /// [Optional] If present, lists orders applying to a specific advert.
  String advertId;

  /// [Optional] Used for paging.
  int limit;

  /// [Optional] Used for paging.
  int offset;

  /// Must be 1
  int p2pOrderList;

  /// [Optional] If set to 1, will send updates whenever there is a change to any order belonging to you.
  int subscribe;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pOrderListRequestToJson(this);
}
