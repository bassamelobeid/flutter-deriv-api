/// generated automatically from flutter_deriv_api|lib/api/get_financial_assessment_send.json
import 'package:json_annotation/json_annotation.dart';

import 'request.dart';

part 'get_financial_assessment_send.g.dart';

/// JSON conversion for 'get_financial_assessment_send'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class GetFinancialAssessmentRequest extends Request {
  /// Initialize GetFinancialAssessmentRequest
  GetFinancialAssessmentRequest({
    this.getFinancialAssessment = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates instance from JSON
  factory GetFinancialAssessmentRequest.fromJson(Map<String, dynamic> json) =>
      _$GetFinancialAssessmentRequestFromJson(json);

  // Properties
  /// Must be `1`
  final int getFinancialAssessment;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$GetFinancialAssessmentRequestToJson(this);
}
