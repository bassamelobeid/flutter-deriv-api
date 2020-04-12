/// generated automatically from flutter_deriv_api|lib/api/p2p_advertiser_update_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'p2p_advertiser_update_receive.g.dart';

/// JSON conversion for 'p2p_advertiser_update_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pAdvertiserUpdateResponse extends Response {
  /// Initialize P2pAdvertiserUpdateResponse
  P2pAdvertiserUpdateResponse({
    this.p2pAdvertiserUpdate,
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
  factory P2pAdvertiserUpdateResponse.fromJson(Map<String, dynamic> json) =>
      _$P2pAdvertiserUpdateResponseFromJson(json);

  // Properties
  /// P2P advertiser information.
  final Map<String, dynamic> p2pAdvertiserUpdate;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pAdvertiserUpdateResponseToJson(this);
}
