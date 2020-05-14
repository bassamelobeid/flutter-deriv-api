import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_deriv_api/api/models/enums.dart';
import 'package:flutter_deriv_api/api/p2p/p2p_advert/p2p_advert.dart';
import 'package:flutter_deriv_api/basic_api/generated/api.dart';
import 'package:flutter_deriv_api/services/dependency_injector/injector.dart';
import 'package:flutter_deriv_api/services/dependency_injector/module_container.dart';
import 'package:flutter_deriv_api/utils/helpers.dart';

void main() {
  group('p2p advert group ->', () {
    ModuleContainer().initialize(Injector.getInjector(), isMock: true);

    test('fetch advert information', () async {
      final P2PAdvert advert = await P2PAdvert.fetchAdvert(
        const P2pAdvertInfoRequest(id: '6'),
      );

      expect(advert.accountCurrency, 'USD');

      expect(advert.advertiserDetails.id, '2');
      expect(advert.advertiserDetails.name, 'za advertiser 1010');

      expect(advert.counterpartyType, TransactionType.sell);
      expect(advert.country, 'za');
      expect(advert.createdTime, getDateTime(1589279547));
      expect(
        advert.description,
        'Please transfer to account number 1234',
      );
      expect(advert.id, '21');
      expect(advert.isActive, true);
      expect(advert.localCurrency, 'ZAR');
      expect(advert.maxOrderAmountLimit, 15);
      expect(advert.maxOrderAmountLimitDisplay, '15.00');
      expect(advert.minOrderAmountLimit, 3);
      expect(advert.minOrderAmountLimitDisplay, '3.00');
      expect(advert.paymentMethod, PaymentMethod.bankTransfer);
      expect(advert.price, 2.3);
      expect(advert.priceDisplay, '2.30');
      expect(advert.rate, 2.3);
      expect(advert.rateDisplay, '2.30');
      expect(advert.type, TransactionType.buy);
    });

    test('fetch advert list', () async {
      final List<P2PAdvert> adverts = await P2PAdvert.fetchAdvertList(
        const P2pAdvertListRequest(
          counterpartyType: 'sell',
        ),
      );

      expect(adverts.length, 2);

      expect(adverts.first.accountCurrency, 'USD');

      expect(adverts.first.advertiserDetails.id, '6');
      expect(
        adverts.first.advertiserDetails.name,
        'advertiser CR90000018',
      );

      expect(adverts.first.counterpartyType, TransactionType.sell);
      expect(adverts.first.country, 'za');
      expect(adverts.first.createdTime, getDateTime(1589270475));
      expect(
        adverts.first.description,
        'Please contact via whats app 1234',
      );
      expect(adverts.first.id, '7');
      expect(adverts.first.isActive, true);
      expect(adverts.first.localCurrency, 'ZAR');
      expect(adverts.first.maxOrderAmountLimit, 100);
      expect(adverts.first.maxOrderAmountLimitDisplay, '100.00');
      expect(adverts.first.minOrderAmountLimit, 10);
      expect(adverts.first.minOrderAmountLimitDisplay, '10.00');
      expect(adverts.first.paymentMethod, PaymentMethod.bankTransfer);
      expect(adverts.first.price, 14500);
      expect(adverts.first.priceDisplay, '14500.00');
      expect(adverts.first.rate, 14500);
      expect(adverts.first.rateDisplay, '14500.00');
      expect(adverts.first.type, TransactionType.buy);
    });

    test('create advert', () async {
      final P2PAdvert advert = await P2PAdvert.createAdvert(
        const P2pAdvertCreateRequest(
          description: 'Please transfer to account number 1234',
          type: 'buy',
          amount: 100,
          maxOrderAmount: 15,
          minOrderAmount: 3,
          paymentMethod: 'bank_transfer',
          rate: 4.25,
        ),
      );

      expect(advert.accountCurrency, 'USD');

      expect(advert.advertiserDetails.id, '3');
      expect(advert.advertiserDetails.name, 'za advertiser 1010');

      expect(advert.amount, 100);
      expect(advert.amountDisplay, '100.00');
      expect(advert.contactInfo, 'Please transfer to account number 1234');
      expect(advert.counterpartyType, TransactionType.buy);
      expect(advert.country, 'za');
      expect(advert.createdTime, getDateTime(1589279547));
      expect(advert.description, 'advert information');
      expect(advert.id, '25');
      expect(advert.isActive, true);
      expect(advert.localCurrency, 'ZAR');
      expect(advert.maxOrderAmount, 50);
      expect(advert.maxOrderAmountDisplay, '50.00');
      expect(advert.minOrderAmount, 20);
      expect(advert.minOrderAmountDisplay, '20.00');
      expect(advert.paymentInfo, 'it is a sell order');
      expect(advert.paymentMethod, PaymentMethod.bankTransfer);
      expect(advert.price, 2.3);
      expect(advert.priceDisplay, '2.30');
      expect(advert.rate, 2.7);
      expect(advert.rateDisplay, '2.70');
      expect(advert.remainingAmount, 50);
      expect(advert.remainingAmountDisplay, '50.00');
      expect(advert.type, TransactionType.sell);
    });

    test('update advert', () async {
      final P2PAdvert advert = await P2PAdvert.updateAdvert(
        const P2pAdvertUpdateRequest(
          delete: 0,
          isActive: 0,
        ),
      );

      expect(advert.accountCurrency, 'USD');

      expect(advert.advertiserDetails.id, '3');
      expect(advert.advertiserDetails.name, 'za advertiser 1010');

      expect(advert.amount, 100);
      expect(advert.amountDisplay, '100.00');
      expect(advert.contactInfo, 'Please transfer to account number 1234');
      expect(advert.counterpartyType, TransactionType.buy);
      expect(advert.country, 'za');
      expect(advert.createdTime, getDateTime(1589279547));
      expect(advert.description, 'advert information');
      expect(advert.id, '25');
      expect(advert.isActive, false);
      expect(advert.localCurrency, 'ZAR');
      expect(advert.maxOrderAmount, 50);
      expect(advert.maxOrderAmountDisplay, '50.00');
      expect(advert.minOrderAmount, 20);
      expect(advert.minOrderAmountDisplay, '20.00');
      expect(advert.paymentInfo, 'it is a sell order');
      expect(advert.paymentMethod, PaymentMethod.bankTransfer);
      expect(advert.price, 2.3);
      expect(advert.priceDisplay, '2.30');
      expect(advert.rate, 2.7);
      expect(advert.rateDisplay, '2.70');
      expect(advert.remainingAmount, 50);
      expect(advert.remainingAmountDisplay, '50.00');
      expect(advert.type, TransactionType.sell);
    });
  });
}
