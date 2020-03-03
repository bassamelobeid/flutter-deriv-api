/// Autogenerated from flutter_deriv_api|lib/api/request_report_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'request_report_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class RequestReportRequest extends Request {
  ///
  RequestReportRequest(
      {this.dateFrom,
      this.dateTo,
      Map<String, dynamic> passthrough,
      this.reportType,
      int reqId,
      this.requestReport})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory RequestReportRequest.fromJson(Map<String, dynamic> json) =>
      _$RequestReportRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$RequestReportRequestToJson(this);

  // Properties
  /// Start date of the report
  int dateFrom;

  /// End date of the report
  int dateTo;

  /// Type of report to be sent to client's registered e-mail address
  String reportType;

  /// Must be `1`
  int requestReport;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
