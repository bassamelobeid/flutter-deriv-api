/// Autogenerated from flutter_deriv_api|lib/api/get_financial_assessment_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'get_financial_assessment_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class GetFinancialAssessmentRequest extends Request {
  ///
  GetFinancialAssessmentRequest(
      {this.getFinancialAssessment,
      Map<String, dynamic> passthrough,
      int reqId})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory GetFinancialAssessmentRequest.fromJson(Map<String, dynamic> json) =>
      _$GetFinancialAssessmentRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$GetFinancialAssessmentRequestToJson(this);

  // Properties
  /// Must be `1`
  int getFinancialAssessment;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
