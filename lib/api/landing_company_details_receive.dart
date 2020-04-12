/// generated automatically from flutter_deriv_api|lib/api/landing_company_details_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'landing_company_details_receive.g.dart';

/// JSON conversion for 'landing_company_details_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class LandingCompanyDetailsResponse extends Response {
  /// Initialize LandingCompanyDetailsResponse
  LandingCompanyDetailsResponse({
    this.landingCompanyDetails,
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
  factory LandingCompanyDetailsResponse.fromJson(Map<String, dynamic> json) =>
      _$LandingCompanyDetailsResponseFromJson(json);

  // Properties
  /// The detailed information of the requested landing company.
  final Map<String, dynamic> landingCompanyDetails;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$LandingCompanyDetailsResponseToJson(this);
}
