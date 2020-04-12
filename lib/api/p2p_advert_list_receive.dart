/// generated automatically from flutter_deriv_api|lib/api/p2p_advert_list_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'p2p_advert_list_receive.g.dart';

/// JSON conversion for 'p2p_advert_list_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pAdvertListResponse extends Response {
  /// Initialize P2pAdvertListResponse
  P2pAdvertListResponse({
    this.p2pAdvertList,
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
  factory P2pAdvertListResponse.fromJson(Map<String, dynamic> json) =>
      _$P2pAdvertListResponseFromJson(json);

  // Properties
  /// P2P adverts list.
  final Map<String, dynamic> p2pAdvertList;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pAdvertListResponseToJson(this);
}
