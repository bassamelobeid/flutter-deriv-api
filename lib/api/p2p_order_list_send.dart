/// generated automatically from flutter_deriv_api|lib/api/p2p_order_list_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'p2p_order_list_send.g.dart';

/// JSON conversion for 'p2p_order_list_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pOrderListRequest extends Request {
  /// Initialize P2pOrderListRequest
  P2pOrderListRequest({
    this.active,
    this.advertId,
    this.limit,
    this.offset,
    this.p2pOrderList = 1,
    this.subscribe,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory P2pOrderListRequest.fromJson(Map<String, dynamic> json) =>
      _$P2pOrderListRequestFromJson(json);

  // Properties
  /// [Optional] Should be 1 to list active, 0 to list inactive (historical).
  final num active;

  /// [Optional] If present, lists orders applying to a specific advert.
  final String advertId;

  /// [Optional] Used for paging.
  final int limit;

  /// [Optional] Used for paging.
  final int offset;

  /// Must be 1
  final int p2pOrderList;

  /// [Optional] If set to 1, will send updates whenever there is a change to any order belonging to you.
  final int subscribe;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pOrderListRequestToJson(this);
}
