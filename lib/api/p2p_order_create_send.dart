/// Autogenerated from flutter_deriv_api|lib/api/p2p_order_create_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'p2p_order_create_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pOrderCreateRequest extends Request {
  ///
  P2pOrderCreateRequest(
      {this.advertId,
      this.amount,
      this.contactInfo,
      this.p2pOrderCreate,
      Map<String, dynamic> passthrough,
      this.paymentInfo,
      int reqId,
      this.subscribe})
      : super(passthrough: passthrough, reqId: reqId);

  ///
  factory P2pOrderCreateRequest.fromJson(Map<String, dynamic> json) =>
      _$P2pOrderCreateRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$P2pOrderCreateRequestToJson(this);

  // Properties
  /// The unique identifier for the advert to create an order against.
  String advertId;

  /// The amount of currency to be bought or sold.
  num amount;

  /// [Optional] Only available for sell orders. Details for how the buyer can contact the seller.
  String contactInfo;

  /// Must be 1
  int p2pOrderCreate;

  /// [Optional] Only available for sell orders. Instructions for how the buyer can transfer funds, for example: bank name and account number, or E-Wallet id.
  String paymentInfo;

  /// [Optional] If set to 1, will send updates whenever there is an update to the order.
  int subscribe;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
