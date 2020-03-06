/// Autogenerated from flutter_deriv_api|lib/api/copytrading_list_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'copytrading_list_send.g.dart';

/// JSON conversion for 'copytrading_list_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class CopytradingListRequest extends Request {
  /// Initialize CopytradingListRequest
  CopytradingListRequest(
      {this.copytradingList, int reqId, Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  /// Factory constructor to initialize from JSON
  factory CopytradingListRequest.fromJson(Map<String, dynamic> json) =>
      _$CopytradingListRequestFromJson(json);

  // Properties
  /// Must be `1`
  int copytradingList;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$CopytradingListRequestToJson(this);
}
