/// Autogenerated from flutter_deriv_api|lib/api/asset_index_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'asset_index_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AssetIndexResponse extends Response {
  ///
  AssetIndexResponse(
      {this.assetIndex,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  ///
  factory AssetIndexResponse.fromJson(Map<String, dynamic> json) =>
      _$AssetIndexResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$AssetIndexResponseToJson(this);

  // Properties
  /// List of underlyings by their display name and symbol followed by their available contract types and duration boundaries.
  List<String> assetIndex;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
