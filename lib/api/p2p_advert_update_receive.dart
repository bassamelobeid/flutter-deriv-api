/// Autogenerated from flutter_deriv_api|lib/api/p2p_advert_update_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'p2p_advert_update_receive.g.dart';

/// JSON conversion for 'p2p_advert_update_receive'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class P2pAdvertUpdateResponse extends Response {
  /// Initialize P2pAdvertUpdateResponse
  P2pAdvertUpdateResponse(
      {this.p2pAdvertUpdate,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory P2pAdvertUpdateResponse.fromJson(Map<String, dynamic> json) =>
      _$P2pAdvertUpdateResponseFromJson(json);

  // Properties
  /// P2P updated advert information.
  Map<String, dynamic> p2pAdvertUpdate;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$P2pAdvertUpdateResponseToJson(this);
}
