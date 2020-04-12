/// generated automatically from flutter_deriv_api|lib/api/p2p_advert_create_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'p2p_advert_create_receive.g.dart';

/// JSON conversion for 'p2p_advert_create_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pAdvertCreateResponse extends Response {
  /// Initialize P2pAdvertCreateResponse
  P2pAdvertCreateResponse({
    this.p2pAdvertCreate,
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
  factory P2pAdvertCreateResponse.fromJson(Map<String, dynamic> json) =>
      _$P2pAdvertCreateResponseFromJson(json);

  // Properties
  /// The information of the created P2P advert.
  final Map<String, dynamic> p2pAdvertCreate;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pAdvertCreateResponseToJson(this);
}
