/// Autogenerated from flutter_deriv_api|lib/api/contract_update_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'contract_update_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ContractUpdateResponse extends Response {
  ///
  ContractUpdateResponse(
      {this.contractUpdate,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory ContractUpdateResponse.fromJson(Map<String, dynamic> json) =>
      _$ContractUpdateResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$ContractUpdateResponseToJson(this);

  // Properties
  /// Contains the update status of the request
  Map<String, dynamic> contractUpdate;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
