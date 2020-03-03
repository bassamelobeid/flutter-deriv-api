/// Autogenerated from flutter_deriv_api|lib/api/forget_all_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'forget_all_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ForgetAllRequest extends Request {
  ///
  ForgetAllRequest(
      {this.forgetAll, Map<String, dynamic> passthrough, int reqId})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory ForgetAllRequest.fromJson(Map<String, dynamic> json) =>
      _$ForgetAllRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$ForgetAllRequestToJson(this);

  // Properties
  /// Cancel all streams by type (it can be a single string e.g. 'ticks', or an array of multiple values, e.g. ['ticks', 'candles']). Possible values are: 'ticks', 'candles', 'proposal', 'proposal_open_contract', 'balance', 'transaction', 'proposal_array', 'website_status', 'p2p_order'.
  String forgetAll;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
