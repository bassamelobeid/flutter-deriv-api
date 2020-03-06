/// Autogenerated from flutter_deriv_api|lib/api/portfolio_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'portfolio_receive.g.dart';

/// JSON conversion for 'portfolio_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PortfolioResponse extends Response {
  /// Initialize PortfolioResponse
  PortfolioResponse(
      {this.portfolio,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory PortfolioResponse.fromJson(Map<String, dynamic> json) =>
      _$PortfolioResponseFromJson(json);

  // Properties
  /// Current account's open positions.
  Map<String, dynamic> portfolio;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$PortfolioResponseToJson(this);
}
