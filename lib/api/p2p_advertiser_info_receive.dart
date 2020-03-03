/// Autogenerated from flutter_deriv_api|lib/api/p2p_advertiser_info_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'p2p_advertiser_info_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pAdvertiserInfoResponse extends Response {
  ///
  P2pAdvertiserInfoResponse(
      {Map<String, dynamic> echoReq,
      String msgType,
      this.p2pAdvertiserInfo,
      int reqId})
      : super(echoReq: echoReq, msgType: msgType, reqId: reqId);

  ///
  factory P2pAdvertiserInfoResponse.fromJson(Map<String, dynamic> json) =>
      _$P2pAdvertiserInfoResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$P2pAdvertiserInfoResponseToJson(this);

  // Properties

  /// P2P advertiser information.
  Map<String, dynamic> p2pAdvertiserInfo;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
