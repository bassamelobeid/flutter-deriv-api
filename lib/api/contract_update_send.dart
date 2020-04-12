/// generated automatically from flutter_deriv_api|lib/api/contract_update_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'contract_update_send.g.dart';

/// JSON conversion for 'contract_update_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ContractUpdateRequest extends Request {
  /// Initialize ContractUpdateRequest
  ContractUpdateRequest({
    this.contractId,
    this.contractUpdate = 1,
    this.limitOrder,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory ContractUpdateRequest.fromJson(Map<String, dynamic> json) =>
      _$ContractUpdateRequestFromJson(json);

  // Properties
  /// Internal unique contract identifier.
  final int contractId;

  /// Must be `1`
  final int contractUpdate;

  /// Specify limit order to update.
  final Map<String, dynamic> limitOrder;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$ContractUpdateRequestToJson(this);
}
