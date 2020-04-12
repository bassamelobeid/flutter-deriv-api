/// generated automatically from flutter_deriv_api|lib/api/paymentagent_transfer_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'paymentagent_transfer_receive.g.dart';

/// JSON conversion for 'paymentagent_transfer_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PaymentagentTransferResponse extends Response {
  /// Initialize PaymentagentTransferResponse
  PaymentagentTransferResponse({
    this.clientToFullName,
    this.clientToLoginid,
    this.paymentagentTransfer,
    this.transactionId,
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
  factory PaymentagentTransferResponse.fromJson(Map<String, dynamic> json) =>
      _$PaymentagentTransferResponseFromJson(json);

  // Properties
  /// The `transfer_to` client full name
  final String clientToFullName;

  /// The `transfer_to` client loginid
  final String clientToLoginid;

  /// If set to `1`, transfer success. If set to `2`, dry-run success.
  final int paymentagentTransfer;

  /// Reference ID of transfer performed
  final int transactionId;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$PaymentagentTransferResponseToJson(this);
}
