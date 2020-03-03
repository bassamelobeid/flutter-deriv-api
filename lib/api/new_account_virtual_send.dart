/// Autogenerated from flutter_deriv_api|lib/api/new_account_virtual_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'new_account_virtual_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class NewAccountVirtualRequest extends Request {
  ///
  NewAccountVirtualRequest(
      {this.affiliateToken,
      this.clientPassword,
      this.dateFirstContact,
      this.gclidUrl,
      this.newAccountVirtual,
      Map<String, dynamic> passthrough,
      int reqId,
      this.residence,
      this.signupDevice,
      this.utmCampaign,
      this.utmMedium,
      this.utmSource,
      this.verificationCode})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory NewAccountVirtualRequest.fromJson(Map<String, dynamic> json) =>
      _$NewAccountVirtualRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$NewAccountVirtualRequestToJson(this);

  // Properties
  /// [Optional] Affiliate token, within 32 characters.
  String affiliateToken;

  /// Password (length within 6-25 chars, accepts any printable ASCII character).
  String clientPassword;

  /// [Optional] Date of first contact, format: `yyyy-mm-dd` in GMT timezone.
  String dateFirstContact;

  /// [Optional] Google Click Identifier to track source.
  String gclidUrl;

  /// Must be `1`
  int newAccountVirtual;

  /// 2-letter country code (obtained from `residence_list` call).
  String residence;

  /// [Optional] Show whether user has used mobile or desktop.
  String signupDevice;

  /// [Optional] Identifies a specific product promotion or strategic campaign such as a spring sale or other promotions.
  String utmCampaign;

  /// [Optional] Identifies the medium the link was used upon such as: email, CPC, or other methods of sharing.
  String utmMedium;

  /// [Optional] Identifies the source of traffic such as: search engine, newsletter, or other referral.
  String utmSource;

  /// Email verification code (received from a `verify_email` call, which must be done first).
  String verificationCode;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
