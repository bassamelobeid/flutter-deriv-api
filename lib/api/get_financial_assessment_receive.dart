/// generated automatically from flutter_deriv_api|lib/api/get_financial_assessment_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'get_financial_assessment_receive.g.dart';

/// JSON conversion for 'get_financial_assessment_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class GetFinancialAssessmentResponse extends Response {
  /// Initialize GetFinancialAssessmentResponse
  GetFinancialAssessmentResponse({
    this.getFinancialAssessment,
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
  factory GetFinancialAssessmentResponse.fromJson(Map<String, dynamic> json) =>
      _$GetFinancialAssessmentResponseFromJson(json);

  // Properties
  /// Client's financial assessment details
  final Map<String, dynamic> getFinancialAssessment;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$GetFinancialAssessmentResponseToJson(this);
}
