// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_markup_details_receive.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AppMarkupDetailsResponse _$AppMarkupDetailsResponseFromJson(
    Map<String, dynamic> json) {
  return AppMarkupDetailsResponse(
    appMarkupDetails: json['app_markup_details'] as Map<String, dynamic>,
    echoReq: json['echo_req'] as Map<String, dynamic>,
    error: json['error'] as Map<String, dynamic>,
    msgType: json['msg_type'] as String,
    reqId: json['req_id'] as int,
  );
}

Map<String, dynamic> _$AppMarkupDetailsResponseToJson(
        AppMarkupDetailsResponse instance) =>
    <String, dynamic>{
      'echo_req': instance.echoReq,
      'error': instance.error,
      'msg_type': instance.msgType,
      'req_id': instance.reqId,
      'app_markup_details': instance.appMarkupDetails,
    };
