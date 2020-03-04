/// Autogenerated from flutter_deriv_api|lib/api/get_account_status_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'get_account_status_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class GetAccountStatusRequest extends Request {
  ///
  GetAccountStatusRequest(
      {this.getAccountStatus, int reqId, Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  ///
  factory GetAccountStatusRequest.fromJson(Map<String, dynamic> json) =>
      _$GetAccountStatusRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$GetAccountStatusRequestToJson(this);

  // Properties
  /// Must be `1`
  int getAccountStatus;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
