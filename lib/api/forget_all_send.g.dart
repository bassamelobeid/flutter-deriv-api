// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'forget_all_send.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ForgetAllRequest _$ForgetAllRequestFromJson(Map<String, dynamic> json) {
  return ForgetAllRequest(
    forgetAll: json['forget_all'] as String,
    passthrough: json['passthrough'] as Map<String, dynamic>,
    reqId: json['req_id'] as int,
  );
}

Map<String, dynamic> _$ForgetAllRequestToJson(ForgetAllRequest instance) =>
    <String, dynamic>{
      'req_id': instance.reqId,
      'passthrough': instance.passthrough,
      'forget_all': instance.forgetAll,
    };
