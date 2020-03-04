/// Autogenerated from flutter_deriv_api|lib/api/get_account_status_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'get_account_status_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class GetAccountStatusResponse extends Response {
  ///
  GetAccountStatusResponse(
      {this.getAccountStatus,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory GetAccountStatusResponse.fromJson(Map<String, dynamic> json) =>
      _$GetAccountStatusResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$GetAccountStatusResponseToJson(this);

  // Properties

  /// Account status details
  Map<String, dynamic> getAccountStatus;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
