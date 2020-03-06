/// Autogenerated from flutter_deriv_api|lib/api/asset_index_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'asset_index_receive.g.dart';

/// JSON conversion for 'asset_index_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AssetIndexResponse extends Response {
  /// Initialize AssetIndexResponse
  AssetIndexResponse(
      {this.assetIndex,
      int reqId,
      Map<String, dynamic> echoReq,
      String msgType,
      Map<String, dynamic> error})
      : super(reqId: reqId, echoReq: echoReq, msgType: msgType, error: error);

  /// Factory constructor to initialize from JSON
  factory AssetIndexResponse.fromJson(Map<String, dynamic> json) =>
      _$AssetIndexResponseFromJson(json);

  // Properties
  /// List of underlyings by their display name and symbol followed by their available contract types and duration boundaries.
  List<String> assetIndex;

  /// Converts this instance to JSON
  @override
  Map<String, dynamic> toJson() => _$AssetIndexResponseToJson(this);
}
