/// Autogenerated from flutter_deriv_api|lib/api/portfolio_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'portfolio_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class PortfolioRequest extends Request {
  ///
  PortfolioRequest(
      {Map<String, dynamic> passthrough, this.portfolio, int reqId})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory PortfolioRequest.fromJson(Map<String, dynamic> json) =>
      _$PortfolioRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$PortfolioRequestToJson(this);

  // Properties

  /// Must be `1`
  int portfolio;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
