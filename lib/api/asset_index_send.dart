/// Autogenerated from flutter_deriv_api|lib/api/asset_index_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'asset_index_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AssetIndexRequest extends Request {
  ///
  AssetIndexRequest(
      {this.assetIndex, this.landingCompany, this.passthrough, this.reqId});

  ///
  factory AssetIndexRequest.fromJson(Map<String, dynamic> json) =>
      _$AssetIndexRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$AssetIndexRequestToJson(this);

  // Properties
  /// Must be `1`
  int assetIndex;

  /// [Optional] If specified, will return only the underlyings for the specified landing company.
  String landingCompany;

  /// [Optional] Used to pass data through the websocket, which may be retrieved via the `echo_req` output field.
  Map<String, dynamic> passthrough;

  /// [Optional] Used to map request to response.
  int reqId;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
