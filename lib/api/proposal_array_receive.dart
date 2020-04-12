/// generated automatically from flutter_deriv_api|lib/api/proposal_array_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'proposal_array_receive.g.dart';

/// JSON conversion for 'proposal_array_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ProposalArrayResponse extends Response {
  /// Initialize ProposalArrayResponse
  ProposalArrayResponse({
    this.proposalArray,
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
  factory ProposalArrayResponse.fromJson(Map<String, dynamic> json) =>
      _$ProposalArrayResponseFromJson(json);

  // Properties
  /// Latest price and other details for a given contract
  final Map<String, dynamic> proposalArray;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$ProposalArrayResponseToJson(this);
}
