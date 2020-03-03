/// Autogenerated from flutter_deriv_api|lib/api/set_settings_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'set_settings_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class SetSettingsRequest extends Request {
  ///
  SetSettingsRequest(
      {this.accountOpeningReason,
      this.addressCity,
      this.addressLine1,
      this.addressLine2,
      this.addressPostcode,
      this.addressState,
      this.allowCopiers,
      this.citizen,
      this.dateOfBirth,
      this.emailConsent,
      this.firstName,
      this.lastName,
      this.passthrough,
      this.phone,
      this.placeOfBirth,
      this.reqId,
      this.requestProfessionalStatus,
      this.residence,
      this.salutation,
      this.secretAnswer,
      this.secretQuestion,
      this.setSettings,
      this.taxIdentificationNumber,
      this.taxResidence});

  ///
  factory SetSettingsRequest.fromJson(Map<String, dynamic> json) =>
      _$SetSettingsRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$SetSettingsRequestToJson(this);

  // Properties
  /// [Optional] Purpose and reason for requesting the account opening. Only applicable for real money account. Required for clients that have not set it yet. Can only be set once.
  String accountOpeningReason;

  /// [Optional] Note: not applicable for virtual account. Required field for real money account.
  String addressCity;

  /// [Optional] Note: not applicable for virtual account. Required field for real money account.
  String addressLine1;

  /// [Optional] Note: not applicable for virtual account. Optional field for real money account.
  String addressLine2;

  /// [Optional] Note: not applicable for virtual account. Optional field for real money account.
  String addressPostcode;

  /// [Optional] Note: not applicable for virtual account. Optional field for real money account.
  String addressState;

  /// [Optional] Boolean value 1 or 0, indicating permission to allow others to follow your trades. Note: not applicable for Virtual account. Only allow for real money account.
  int allowCopiers;

  /// [Optional] Country of legal citizenship, 2-letter country code.
  String citizen;

  /// [Optional] Date of birth format: yyyy-mm-dd (can only be changed on unauthenticated svg accounts).
  String dateOfBirth;

  /// [Optional] Boolean value 1 or 0, indicating permission to use email address for any contact which may include marketing
  int emailConsent;

  /// [Optional] Within 2-50 characters, use only letters, spaces, hyphens, full-stops or apostrophes (can only be changed on unauthenticated svg accounts).
  String firstName;

  /// [Optional] Within 2-50 characters, use only letters, spaces, hyphens, full-stops or apostrophes (can only be changed on unauthenticated svg accounts).
  String lastName;

  /// [Optional] Used to pass data through the websocket, which may be retrieved via the `echo_req` output field.
  Map<String, dynamic> passthrough;

  /// [Optional] Note: not applicable for virtual account. Required field for real money account and within 8-35 digits, allowing '+' in front, numbers, hyphens or space.
  String phone;

  /// [Optional] Place of birth, 2-letter country code.
  String placeOfBirth;

  /// [Optional] Used to map request to response.
  int reqId;

  /// [Optional] Required when client wants to be treated as professional. Applicable for financial accounts only.
  int requestProfessionalStatus;

  /// [Optional] 2-letter country code. Note: not applicable for real money account. Only allow for Virtual account without residence set.
  String residence;

  /// [Optional] Accept any value in enum list (can only be changed on unauthenticated svg accounts).
  String salutation;

  /// [Optional] Answer to secret question, within 4-50 characters. Required for new account and existing client details will be used if client opens another account.
  String secretAnswer;

  /// [Optional] Accept any value in enum list. Required for new account and existing client details will be used if client opens another account.
  String secretQuestion;

  /// Must be `1`
  int setSettings;

  /// [Optional] Tax identification number. Only applicable for real money account. Required for maltainvest landing company.
  String taxIdentificationNumber;

  /// [Optional] Residence for tax purpose. Comma separated iso country code if multiple jurisdictions. Only applicable for real money account. Required for maltainvest landing company.
  String taxResidence;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
