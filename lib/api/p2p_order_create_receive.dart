/// generated automatically from flutter_deriv_api|lib/api/p2p_order_create_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'p2p_order_create_receive.g.dart';

/// JSON conversion for 'p2p_order_create_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pOrderCreateResponse extends Response {
  /// Initialize P2pOrderCreateResponse
  P2pOrderCreateResponse({
    this.p2pOrderCreate,
    this.subscription,
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
  factory P2pOrderCreateResponse.fromJson(Map<String, dynamic> json) =>
      _$P2pOrderCreateResponseFromJson(json);

  // Properties
  /// Information of the creates P2P order.
  final Map<String, dynamic> p2pOrderCreate;

  /// For subscription requests only.
  final Map<String, dynamic> subscription;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pOrderCreateResponseToJson(this);
}
