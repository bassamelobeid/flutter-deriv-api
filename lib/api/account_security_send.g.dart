// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'account_security_send.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AccountSecurityRequest _$AccountSecurityRequestFromJson(
    Map<String, dynamic> json) {
  return AccountSecurityRequest(
    accountSecurity: json['account_security'] as int,
    otp: json['otp'] as String,
    passthrough: json['passthrough'] as Map<String, dynamic>,
    reqId: json['req_id'] as int,
    totpAction: json['totp_action'] as String,
  );
}

Map<String, dynamic> _$AccountSecurityRequestToJson(
        AccountSecurityRequest instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'passthrough': instance.passthrough,
      'account_security': instance.accountSecurity,
      'otp': instance.otp,
      'totp_action': instance.totpAction,
    };
