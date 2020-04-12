/// generated automatically from flutter_deriv_api|lib/api/contract_update_history_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'contract_update_history_send.g.dart';

/// JSON conversion for 'contract_update_history_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ContractUpdateHistoryRequest extends Request {
  /// Initialize ContractUpdateHistoryRequest
  ContractUpdateHistoryRequest({
    this.contractId,
    this.contractUpdateHistory = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory ContractUpdateHistoryRequest.fromJson(Map<String, dynamic> json) =>
      _$ContractUpdateHistoryRequestFromJson(json);

  // Properties
  /// Internal unique contract identifier.
  final int contractId;

  /// Must be `1`
  final int contractUpdateHistory;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$ContractUpdateHistoryRequestToJson(this);
}
