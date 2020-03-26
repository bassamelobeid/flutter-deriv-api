/// Autogenerated from flutter_deriv_api|lib/api/proposal_array_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'proposal_array_receive.g.dart';

/// JSON conversion for 'proposal_array_receive'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class ProposalArrayResponse extends Response {
  /// Initialize ProposalArrayResponse
  ProposalArrayResponse(
      {this.proposalArray,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory ProposalArrayResponse.fromJson(Map<String, dynamic> json) =>
      _$ProposalArrayResponseFromJson(json);

  // Properties
  /// Latest price and other details for a given contract
  Map<String, dynamic> proposalArray;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$ProposalArrayResponseToJson(this);
}
