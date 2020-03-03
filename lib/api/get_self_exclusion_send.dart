/// Autogenerated from flutter_deriv_api|lib/api/get_self_exclusion_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'get_self_exclusion_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class GetSelfExclusionRequest extends Request {
  ///
  GetSelfExclusionRequest(
      {this.getSelfExclusion, Map<String, dynamic> passthrough, int reqId})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory GetSelfExclusionRequest.fromJson(Map<String, dynamic> json) =>
      _$GetSelfExclusionRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$GetSelfExclusionRequestToJson(this);

  // Properties
  /// Must be `1`
  int getSelfExclusion;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
