/// Autogenerated from flutter_deriv_api|lib/api/document_upload_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'document_upload_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class DocumentUploadRequest extends Request {
  ///
  DocumentUploadRequest(
      {this.documentFormat,
      this.documentId,
      this.documentType,
      this.documentUpload,
      this.expectedChecksum,
      this.expirationDate,
      this.fileSize,
      this.pageType,
      int reqId,
      Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  ///
  factory DocumentUploadRequest.fromJson(Map<String, dynamic> json) =>
      _$DocumentUploadRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$DocumentUploadRequestToJson(this);

  // Properties
  /// Document file format
  String documentFormat;

  /// [Optional] Document ID (required for Passport, Proof of ID and Driver's License)
  String documentId;

  /// Document type
  String documentType;

  /// Must be `1`
  int documentUpload;

  /// The checksum of the file to be uploaded
  String expectedChecksum;

  /// [Optional] Document expiration date (required for Passport, Proof of ID and Driver's License)
  String expirationDate;

  /// Document size (should be less than 3MB)
  int fileSize;

  /// [Optional] To determine document side
  String pageType;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
