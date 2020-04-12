/// generated automatically from flutter_deriv_api|lib/api/tnc_approval_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'tnc_approval_receive.g.dart';

/// JSON conversion for 'tnc_approval_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class TncApprovalResponse extends Response {
  /// Initialize TncApprovalResponse
  TncApprovalResponse({
    this.tncApproval,
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
  factory TncApprovalResponse.fromJson(Map<String, dynamic> json) =>
      _$TncApprovalResponseFromJson(json);

  // Properties
  /// Set terms and conditions 1: success
  final int tncApproval;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$TncApprovalResponseToJson(this);
}
