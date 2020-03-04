/// Autogenerated from flutter_deriv_api|lib/api/new_account_virtual_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'new_account_virtual_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class NewAccountVirtualResponse extends Response {
  ///
  NewAccountVirtualResponse(
      {this.newAccountVirtual,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory NewAccountVirtualResponse.fromJson(Map<String, dynamic> json) =>
      _$NewAccountVirtualResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$NewAccountVirtualResponseToJson(this);

  // Properties

  /// New virtual-money account details
  Map<String, dynamic> newAccountVirtual;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
