import 'package:deriv_dependency_injector/dependency_injector.dart';
import 'package:flutter_deriv_api/api/exceptions/base_api_exception.dart';
import 'package:flutter_deriv_api/api/models/base_exception_model.dart';
import 'package:flutter_deriv_api/api/response/exchange_rates_response_result.dart';
import 'package:flutter_deriv_api/basic_api/generated/exchange_rates_receive.dart';
import 'package:flutter_deriv_api/basic_api/generated/exchange_rates_send.dart';
import 'package:flutter_deriv_api/basic_api/response.dart';
import 'package:flutter_deriv_api/helpers/helpers.dart';
import 'package:flutter_deriv_api/services/connection/api_manager/base_api.dart';
import 'package:flutter_deriv_api/services/connection/call_manager/base_call_manager.dart';

/// Extended functionality for [ExchangeRatesResponse] class.
class ExchangeRatesResponseExtended extends ExchangeRatesResponse {
  static final BaseAPI _api = Injector()<BaseAPI>();

  /// This will subscribe to currency exchange.<br>
  /// Inside [ExchangeRateRequest] class:
  /// [baseCurrency]: currency that should be exchanged like USD, BTC or any other.
  /// [targetCurrency]: currency that you want to exchange to.
  /// Incase of error, It will throw [BaseAPIException].
  static Stream<ExchangeRatesResponse?> subscribeToExchangeRates(
    ExchangeRatesRequest request, {
    RequestCompareFunction? comparePredicate,
  }) =>
      _api
          .subscribe(request: request, comparePredicate: comparePredicate)!
          .map<ExchangeRatesResponse?>(
        (Response response) {
          checkException(
            response: response,
            exceptionCreator: ({BaseExceptionModel? baseExceptionModel}) =>
                BaseAPIException(baseExceptionModel: baseExceptionModel),
          );

          return response is ExchangeRatesReceive
              ? ExchangeRatesResponse.fromJson(
                  response.exchangeRates, response.subscription)
              : null;
        },
      );
}
