import 'package:flutter_deriv_api/api/models/enums.dart';
import 'package:flutter_deriv_api/api/mt5/exceptions/mt5_exception.dart';
import 'package:flutter_deriv_api/api/mt5/models/mt5_account_model.dart';
import 'package:flutter_deriv_api/basic_api/generated/api.dart';
import 'package:flutter_deriv_api/services/connection/api_manager/base_api.dart';
import 'package:flutter_deriv_api/services/dependency_injector/injector.dart';
import 'package:flutter_deriv_api/utils/helpers.dart';

/// MT5 account class
class MT5Account extends MT5AccountModel {
  /// Initializes
  MT5Account({
    AccountType accountType,
    double balance,
    String country,
    String currency,
    String displayBalance,
    String email,
    String group,
    int leverage,
    String login,
    MT5AccountType mt5AccountType,
    String name,
  }) : super(
          accountType: accountType,
          balance: balance,
          country: country,
          currency: currency,
          displayBalance: displayBalance,
          email: email,
          group: group,
          leverage: leverage,
          login: login,
          mt5AccountType: mt5AccountType,
          name: name,
        );

  /// Creates an instance from JSON
  factory MT5Account.fromJson(Map<String, dynamic> json) => MT5Account(
        accountType: getEnumFromString(
          values: AccountType.values,
          name: json['account_type'],
        ),
        balance: json['balance'],
        country: json['country'],
        currency: json['currency'],
        displayBalance: json['display_balance'],
        email: json['email'],
        group: json['group'],
        leverage: json['leverage'],
        login: json['login'],
        mt5AccountType: getEnumFromString(
          values: MT5AccountType.values,
          name: json['mt5_account_type'],
        ),
        name: json['name'],
      );

  static final BaseAPI _api = Injector.getInjector().get<BaseAPI>();

  /// Creates a copy of instance with given parameters
  MT5Account copyWith({
    AccountType accountType,
    double balance,
    String country,
    String currency,
    String displayBalance,
    String email,
    String group,
    int leverage,
    String login,
    MT5AccountType mt5AccountType,
    String name,
  }) =>
      MT5Account(
        accountType: accountType ?? this.accountType,
        balance: balance ?? this.balance,
        country: country ?? this.country,
        currency: currency ?? this.currency,
        displayBalance: displayBalance ?? this.displayBalance,
        email: email ?? this.email,
        group: group ?? this.group,
        leverage: leverage ?? this.leverage,
        login: login ?? this.login,
        mt5AccountType: mt5AccountType ?? this.mt5AccountType,
        name: name ?? this.name,
      );

  /// This call creates new MT5 user, either demo or real money user
  /// For parameters information refer to [Mt5NewAccountRequest]
  static Future<MT5Account> createNewAccount({
    Mt5NewAccountRequest request,
  }) async {
    final Mt5NewAccountResponse response = await _api.call(request: request);

    if (response.error != null) {
      throw MT5Exception(message: response.error['message']);
    }

    return MT5Account.fromJson(response.mt5NewAccount);
  }

  /// Get list of MT5 accounts for client
  /// For parameters information refer to [Mt5LoginListRequest]
  static Future<List<MT5Account>> fetchLoginList({
    Mt5LoginListRequest request,
  }) async {
    final Mt5LoginListResponse response = await _api.call(request: request);

    if (response.error != null) {
      throw MT5Exception(message: response.error['message']);
    }

    return getListFromMap(
      response.mt5LoginList,
      itemToTypeCallback: (dynamic item) => MT5Account.fromJson(item),
    );
  }
}
