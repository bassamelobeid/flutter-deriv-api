/// Autogenerated from flutter_deriv_api|lib/api/proposal_open_contract_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'proposal_open_contract_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ProposalOpenContractResponse extends Response {
  ///
  ProposalOpenContractResponse(
      {this.proposalOpenContract,
      this.subscription,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory ProposalOpenContractResponse.fromJson(Map<String, dynamic> json) =>
      _$ProposalOpenContractResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$ProposalOpenContractResponseToJson(this);

  // Properties

  /// Latest price and other details for an open contract
  Map<String, dynamic> proposalOpenContract;

  /// For subscription requests only
  Map<String, dynamic> subscription;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
