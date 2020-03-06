/// Autogenerated from flutter_deriv_api|lib/api/landing_company_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'landing_company_receive.g.dart';

/// JSON conversion for 'landing_company_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class LandingCompanyResponse extends Response {
  /// Initialize LandingCompanyResponse
  LandingCompanyResponse(
      {this.landingCompany,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory LandingCompanyResponse.fromJson(Map<String, dynamic> json) =>
      _$LandingCompanyResponseFromJson(json);

  // Properties
  /// Landing Company
  Map<String, dynamic> landingCompany;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$LandingCompanyResponseToJson(this);
}
