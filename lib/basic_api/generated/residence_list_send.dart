/// Generated automatically from flutter_deriv_api|lib/basic_api/generated/residence_list_send.json
import 'package:json_annotation/json_annotation.dart';

import '../request.dart';

part 'residence_list_send.g.dart';

/// JSON conversion for 'residence_list_send'
@JsonSerializable(nullable: true, fieldRename: FieldRename.snake)
class ResidenceListRequest extends Request {
  /// Initialize ResidenceListRequest
  const ResidenceListRequest({
    this.residenceList = 1,
    Map<String, dynamic> passthrough,
    int reqId,
  }) : super(
          msgType: 'residence_list',
          passthrough: passthrough,
          reqId: reqId,
        );

  /// Creates an instance from JSON
  factory ResidenceListRequest.fromJson(Map<String, dynamic> json) =>
      _$ResidenceListRequestFromJson(json);

  /// Must be `1`
  final int residenceList;

  /// Converts an instance to JSON
  @override
  Map<String, dynamic> toJson() => _$ResidenceListRequestToJson(this);

  /// Creates a copy of instance with given parameters
  @override
  ResidenceListRequest copyWith({
    int residenceList,
    Map<String, dynamic> passthrough,
    int reqId,
  }) =>
      ResidenceListRequest(
        residenceList: residenceList ?? this.residenceList,
        passthrough: passthrough ?? this.passthrough,
        reqId: reqId ?? this.reqId,
      );

  /// Override equatable class
  @override
  List<Object> get props => null;
}
