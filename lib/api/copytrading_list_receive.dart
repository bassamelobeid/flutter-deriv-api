/// Autogenerated from flutter_deriv_api|lib/api/copytrading_list_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'copytrading_list_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class CopytradingListResponse extends Response {
  ///
  CopytradingListResponse(
      {this.copytradingList, this.echoReq, this.msgType, this.reqId});

  ///
  factory CopytradingListResponse.fromJson(Map<String, dynamic> json) =>
      _$CopytradingListResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$CopytradingListResponseToJson(this);

  // Properties
  /// The trading information of copiers or traders.
  Map<String, dynamic> copytradingList;

  /// Echo of the request made.
  Map<String, dynamic> echoReq;

  /// Action name of the request made.
  String msgType;

  /// Optional field sent in request to map to response, present only when request contains `req_id`.
  int reqId;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
