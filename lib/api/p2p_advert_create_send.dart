/// Autogenerated from flutter_deriv_api|lib/api/p2p_advert_create_send.json
import 'dart:async';
import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';
import 'request.dart';

part 'p2p_advert_create_send.g.dart';

///
@JsonSerializable(nullable: false, fieldRename: FieldRename.snake)
class P2pAdvertCreateRequest extends Request {
  ///
  P2pAdvertCreateRequest(
      {this.amount,
      this.contactInfo,
      this.country,
      this.description,
      this.localCurrency,
      this.maxOrderAmount,
      this.minOrderAmount,
      this.p2pAdvertCreate,
      this.paymentInfo,
      this.paymentMethod,
      this.rate,
      this.type,
      int reqId,
      Map<String, dynamic> passthrough})
      : super(reqId: reqId, passthrough: passthrough);

  ///
  factory P2pAdvertCreateRequest.fromJson(Map<String, dynamic> json) =>
      _$P2pAdvertCreateRequestFromJson(json);

  ///
  @override
  Map<String, dynamic> toJson() => _$P2pAdvertCreateRequestToJson(this);

  // Properties
  /// The total amount of the advert, in advertiser's account currency.
  num amount;

  /// [Optional] Only applicable for sell adverts. Contact details of the advertiser, which buyer can use to contact you in a buy order.
  String contactInfo;

  /// [Optional] The target country code of the advert. If not provided, will use client's residence by default.
  String country;

  /// [Optional] Notes and general instructions from the advertiser.
  String description;

  /// [Optional] Local currency for this advert. If not provided, will use the currency of client's residence by default.
  String localCurrency;

  /// Maximum allowed amount for the orders of this advert, in advertiser's `account_currency`. Should be less than or equal to total `amount` of the advert.
  num maxOrderAmount;

  /// Minimum allowed amount for the orders of this advert, in advertiser's `account_currency`. Should be less than `max_order_amount`.
  num minOrderAmount;

  /// Must be 1
  int p2pAdvertCreate;

  /// [Optional] Only applicable for sell adverts. Payment instructions for the buyer to transfer funds, for example: bank name and account number, or E-Wallet id.
  String paymentInfo;

  /// The payment method.
  String paymentMethod;

  /// Conversion rate from advertiser's account currency to `local_currency`.
  num rate;

  /// Whether this is a buy or a sell.
  String type;

  // @override
  // String toString() => name;
  static bool _fromInteger(int v) => (v != 0);
  static int _fromBoolean(bool v) => v ? 1 : 0;
}
