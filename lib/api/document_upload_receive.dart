/// Autogenerated from flutter_deriv_api|lib/api/document_upload_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'document_upload_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class DocumentUploadResponse extends Response {
  ///
  DocumentUploadResponse(
      {this.documentUpload,
      Map<String, dynamic> echoReq,
      String msgType,
      int reqId})
      : super(echoReq: echoReq, msgType: msgType, reqId: reqId);

  ///
  factory DocumentUploadResponse.fromJson(Map<String, dynamic> json) =>
      _$DocumentUploadResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$DocumentUploadResponseToJson(this);

  // Properties
  /// Details of the uploaded documents.
  Map<String, dynamic> documentUpload;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
