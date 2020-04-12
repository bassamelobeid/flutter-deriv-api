/// generated automatically from flutter_deriv_api|lib/api/contracts_for_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'contracts_for_send.g.dart';

/// JSON conversion for 'contracts_for_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ContractsForRequest extends Request {
  /// Initialize ContractsForRequest
  ContractsForRequest({
    this.contractsFor,
    this.currency,
    this.landingCompany,
    this.productType,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory ContractsForRequest.fromJson(Map<String, dynamic> json) =>
      _$ContractsForRequestFromJson(json);

  // Properties
  /// The short symbol name (obtained from `active_symbols` call).
  final String contractsFor;

  /// [Optional] Currency of the contract's stake and payout (obtained from `payout_currencies` call).
  final String currency;

  /// [Optional] Indicates which landing company to get a list of contracts for. If you are logged in, your account's landing company will override this field.
  final String landingCompany;

  /// [Optional] If you specify this field, only contracts tradable through that contract type will be returned.
  final String productType;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$ContractsForRequestToJson(this);
}
