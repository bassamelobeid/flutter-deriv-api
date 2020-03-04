/// Autogenerated from flutter_deriv_api|lib/api/states_list_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'states_list_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class StatesListResponse extends Response {
  ///
  StatesListResponse(
      {this.statesList,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory StatesListResponse.fromJson(Map<String, dynamic> json) =>
      _$StatesListResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$StatesListResponseToJson(this);

  // Properties

  /// List of states.
  List<Map<String, dynamic>> statesList;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
