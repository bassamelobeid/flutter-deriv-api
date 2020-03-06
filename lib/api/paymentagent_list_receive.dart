/// Autogenerated from flutter_deriv_api|lib/api/paymentagent_list_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'paymentagent_list_receive.g.dart';

/// JSON conversion for 'paymentagent_list_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PaymentagentListResponse extends Response {
  /// Initialize PaymentagentListResponse
  PaymentagentListResponse(
      {this.paymentagentList,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory PaymentagentListResponse.fromJson(Map<String, dynamic> json) =>
      _$PaymentagentListResponseFromJson(json);

  // Properties
  /// Payment Agent List
  Map<String, dynamic> paymentagentList;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$PaymentagentListResponseToJson(this);
}
