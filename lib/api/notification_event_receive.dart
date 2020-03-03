/// Autogenerated from flutter_deriv_api|lib/api/notification_event_receive.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'response.dart';

part 'notification_event_receive.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class NotificationEventResponse extends Response {
  ///
  NotificationEventResponse(
      {Map<String, dynamic> echoReq,
      String msgType,
      this.notificationEvent,
      int reqId})
      : super(echoReq: echoReq, msgType: msgType, reqId: reqId);

  ///
  factory NotificationEventResponse.fromJson(Map<String, dynamic> json) =>
      _$NotificationEventResponseFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$NotificationEventResponseToJson(this);

  // Properties

  /// `1`: all actions finished successfully, `0`: at least one or more actions failed.
  int notificationEvent;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
