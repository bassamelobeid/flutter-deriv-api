/// Autogenerated from flutter_deriv_api|lib/api/contracts_for_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'contracts_for_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ContractsForResponse extends Response {
  ///
  ContractsForResponse(
      {this.contractsFor,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory ContractsForResponse.fromJson(Map<String, dynamic> json) =>
      _$ContractsForResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$ContractsForResponseToJson(this);

  // Properties
  /// List of available contracts. Note: if the user is authenticated, then only contracts allowed under his account will be returned.
  Map<String, dynamic> contractsFor;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
