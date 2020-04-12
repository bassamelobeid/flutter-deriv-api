/// generated automatically from flutter_deriv_api|lib/api/asset_index_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'asset_index_receive.g.dart';

/// JSON conversion for 'asset_index_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class AssetIndexResponse extends Response {
  /// Initialize AssetIndexResponse
  AssetIndexResponse({
    this.assetIndex,
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
  factory AssetIndexResponse.fromJson(Map<String, dynamic> json) =>
      _$AssetIndexResponseFromJson(json);

  // Properties
  /// List of underlyings by their display name and symbol followed by their available contract types and duration boundaries.
  final List<String> assetIndex;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$AssetIndexResponseToJson(this);
}
