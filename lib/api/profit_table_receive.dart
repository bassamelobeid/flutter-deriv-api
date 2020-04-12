/// generated automatically from flutter_deriv_api|lib/api/profit_table_receive.json
import 'package:json_annotation/json_annotation.dart';

import 'response.dart';

part 'profit_table_receive.g.dart';

/// JSON conversion for 'profit_table_receive'
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class ProfitTableResponse extends Response {
  /// Initialize ProfitTableResponse
  ProfitTableResponse({
    this.profitTable,
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
  factory ProfitTableResponse.fromJson(Map<String, dynamic> json) =>
      _$ProfitTableResponseFromJson(json);

  // Properties
  /// Account Profit Table.
  final Map<String, dynamic> profitTable;

  /// Converts to JSON
  @override
  Map<String, dynamic> toJson() => _$ProfitTableResponseToJson(this);
}
