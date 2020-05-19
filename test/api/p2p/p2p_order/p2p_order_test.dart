import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_deriv_api/api/p2p/p2p_order/p2p_order.dart';
import 'package:flutter_deriv_api/api/p2p/p2p_order/p2p_order_list.dart';
import 'package:flutter_deriv_api/api/p2p/p2p_advert/p2p_advert.dart';
import 'package:flutter_deriv_api/api/p2p/p2p_advertiser/p2p_advertiser.dart';
import 'package:flutter_deriv_api/api/models/enums.dart';
import 'package:flutter_deriv_api/basic_api/generated/api.dart';
import 'package:flutter_deriv_api/services/dependency_injector/injector.dart';
import 'package:flutter_deriv_api/services/dependency_injector/module_container.dart';
import 'package:flutter_deriv_api/utils/helpers.dart';

void main() {
  group('P2P order group', () {
    ModuleContainer().initialize(Injector.getInjector(), isMock: true);

    test('Order create', () async {
      final P2POrder order = await P2POrder.create(
        const P2pOrderCreateRequest(advertId: '8', amount: 50.0),
      );

      expect(order.accountCurrency, 'USD');
      expect(order.amount, 50.0);
      expect(order.amountDisplay, '50.00');
      expect(order.contactInfo, 'Please contact via whatsapp 1234');
      expect(order.createdTime, getDateTime(1589688096));
      expect(order.expiryTime, getDateTime(1589695296));
      expect(order.id, '107');
      expect(order.isIncoming, false);
      expect(order.localCurrency, 'ZAR');
      expect(order.paymentInfo, 'Transfer to account 000-1111');
      expect(order.price, 675000.0);
      expect(order.priceDisplay, '675000.00');
      expect(order.rate, 13500.0);
      expect(order.rateDisplay, '13500.00');
      expect(order.status, OrderStatusType.pending);
      expect(order.type, OrderType.buy);

      final P2PAdvert advert = order.advertDetails;
      expect(advert.description, 'Please contact via whatsapp 1234');
      expect(advert.id, '8');
      expect(advert.paymentMethod, PaymentMethod.bankTransfer);
      expect(advert.type, TransactionType.sell);

      final P2PAdvertiser advertiser = order.advertiserDetails;
      expect(advertiser.id, '6');
      expect(advertiser.name, 'advertiser CR90000018');
    });

    test('Order list', () async {
      final P2POrderList orderList = await P2POrderList.fetchOrderList();
      final P2POrder firstOrder = orderList.list.first;

      expect(firstOrder.accountCurrency, 'USD');
      expect(firstOrder.amount, 50.0);
      expect(firstOrder.amountDisplay, '50.00');
      expect(firstOrder.contactInfo, 'Please contact via whatsapp 1234');
      expect(firstOrder.createdTime, getDateTime(1589688096));
      expect(firstOrder.expiryTime, getDateTime(1589695296));
      expect(firstOrder.id, '107');
      expect(firstOrder.isIncoming, false);
      expect(firstOrder.localCurrency, 'ZAR');
      expect(firstOrder.paymentInfo, 'Transfer to account 000-1111');
      expect(firstOrder.price, 675000.0);
      expect(firstOrder.priceDisplay, '675000.00');
      expect(firstOrder.rate, 13500.0);
      expect(firstOrder.rateDisplay, '13500.00');
      expect(firstOrder.status, OrderStatusType.pending);
      expect(firstOrder.type, OrderType.buy);

      final P2PAdvert advert = firstOrder.advertDetails;
      expect(advert.description, 'Please contact via whatsapp 1234');
      expect(advert.id, '8');
      expect(advert.paymentMethod, PaymentMethod.bankTransfer);
      expect(advert.type, TransactionType.sell);

      final P2PAdvertiser advertiser = firstOrder.advertiserDetails;
      expect(advertiser.id, '6');
      expect(advertiser.name, 'advertiser CR90000018');
    });

    test('Order info', () async {
      final P2POrder order = await P2POrder.fetchOrder(
        const P2pOrderInfoRequest(id: '108'),
      );

      expect(order.accountCurrency, 'USD');
      expect(order.amount, 50.0);
      expect(order.amountDisplay, '50.00');
      expect(order.contactInfo, 'Please contact via whatsapp 1234');
      expect(order.createdTime, getDateTime(1589688096));
      expect(order.expiryTime, getDateTime(1589695296));
      expect(order.id, '107');
      expect(order.isIncoming, false);
      expect(order.localCurrency, 'ZAR');
      expect(order.paymentInfo, 'Transfer to account 000-1111');
      expect(order.price, 675000.0);
      expect(order.priceDisplay, '675000.00');
      expect(order.rate, 13500.0);
      expect(order.rateDisplay, '13500.00');
      expect(order.status, OrderStatusType.pending);
      expect(order.type, OrderType.buy);

      final P2PAdvert advert = order.advertDetails;
      expect(advert.description, 'Please contact via whatsapp 1234');
      expect(advert.id, '8');
      expect(advert.paymentMethod, PaymentMethod.bankTransfer);
      expect(advert.type, TransactionType.sell);

      final P2PAdvertiser advertiser = order.advertiserDetails;
      expect(advertiser.id, '6');
      expect(advertiser.name, 'advertiser CR90000018');
    });

    test('Order confirm', () async {
      final P2POrder order = await P2POrder.fetchOrder(
        const P2pOrderInfoRequest(id: '107'),
      );

      final P2POrder confirmedOrder = await order.confirm();

      expect(confirmedOrder.status, OrderStatusType.buyerConfirmed);
    });

    test('Order cancel', () async {
      final P2POrder order = await P2POrder.fetchOrder(
        const P2pOrderInfoRequest(id: '107'),
      );

      final P2POrder cancelledOrder = await order.cancel();

      expect(cancelledOrder.status, OrderStatusType.cancelled);
    });

    test('Order create subscription', () {
      P2POrder.createAndSubscribe(const P2pOrderCreateRequest(
        advertId: '8',
        amount: 50.0,
      )).take(1).listen(expectAsync1(
        (P2POrder order) {
          expect(order.accountCurrency, 'USD');
          expect(order.amount, 50.0);
          expect(order.amountDisplay, '50.00');
          expect(order.contactInfo, 'Please contact via whatsapp 1234');
          expect(order.createdTime, getDateTime(1589688096));
          expect(order.expiryTime, getDateTime(1589695296));
          expect(order.id, '107');
          expect(order.isIncoming, false);
          expect(order.localCurrency, 'ZAR');
          expect(order.paymentInfo, 'Transfer to account 000-1111');
          expect(order.price, 675000.0);
          expect(order.priceDisplay, '675000.00');
          expect(order.rate, 13500.0);
          expect(order.rateDisplay, '13500.00');
          expect(order.status, OrderStatusType.pending);
          expect(order.type, OrderType.buy);

          final P2PAdvert advert = order.advertDetails;
          expect(advert.description, 'Please contact via whatsapp 1234');
          expect(advert.id, '8');
          expect(advert.paymentMethod, PaymentMethod.bankTransfer);
          expect(advert.type, TransactionType.sell);

          final P2PAdvertiser advertiser = order.advertiserDetails;
          expect(advertiser.id, '6');
          expect(advertiser.name, 'advertiser CR90000018');

          expect(
            order.subscriptionInformation.id,
            '857cfc96-1014-66ce-9c49-0a4dbd22857a',
          );
        },
      ));
    });

    test('Order list subscription', () {
      P2POrderList.subscribeOrderList().take(1).listen(expectAsync1(
        (P2POrderList orderList) {
          final P2POrder firstOrder = orderList.list.first;

          expect(firstOrder.accountCurrency, 'USD');
          expect(firstOrder.amount, 50.0);
          expect(firstOrder.amountDisplay, '50.00');
          expect(firstOrder.contactInfo, 'Please contact via whatsapp 1234');
          expect(firstOrder.createdTime, getDateTime(1589688096));
          expect(firstOrder.expiryTime, getDateTime(1589695296));
          expect(firstOrder.id, '107');
          expect(firstOrder.isIncoming, false);
          expect(firstOrder.localCurrency, 'ZAR');
          expect(firstOrder.paymentInfo, 'Transfer to account 000-1111');
          expect(firstOrder.price, 675000.0);
          expect(firstOrder.priceDisplay, '675000.00');
          expect(firstOrder.rate, 13500.0);
          expect(firstOrder.rateDisplay, '13500.00');
          expect(firstOrder.status, OrderStatusType.pending);
          expect(firstOrder.type, OrderType.buy);

          final P2PAdvert advert = firstOrder.advertDetails;
          expect(advert.description, 'Please contact via whatsapp 1234');
          expect(advert.id, '8');
          expect(advert.paymentMethod, PaymentMethod.bankTransfer);
          expect(advert.type, TransactionType.sell);

          final P2PAdvertiser advertiser = firstOrder.advertiserDetails;
          expect(advertiser.id, '6');
          expect(advertiser.name, 'advertiser CR90000018');

          expect(
            orderList.subscriptionInformation.id,
            '857cfc96-1014-66ce-9c49-0a4dbd22857a',
          );
        },
      ));
    });

    test('Order info subscription', () {
      P2POrder.subscribeOrder(const P2pOrderInfoRequest(id: '107'))
          .take(1)
          .listen(expectAsync1(
        (P2POrder order) {
          expect(order.accountCurrency, 'USD');
          expect(order.amount, 50.0);
          expect(order.amountDisplay, '50.00');
          expect(order.contactInfo, 'Please contact via whatsapp 1234');
          expect(order.createdTime, getDateTime(1589688096));
          expect(order.expiryTime, getDateTime(1589695296));
          expect(order.id, '107');
          expect(order.isIncoming, false);
          expect(order.localCurrency, 'ZAR');
          expect(order.paymentInfo, 'Transfer to account 000-1111');
          expect(order.price, 675000.0);
          expect(order.priceDisplay, '675000.00');
          expect(order.rate, 13500.0);
          expect(order.rateDisplay, '13500.00');
          expect(order.status, OrderStatusType.pending);
          expect(order.type, OrderType.buy);

          final P2PAdvert advert = order.advertDetails;
          expect(advert.description, 'Please contact via whatsapp 1234');
          expect(advert.id, '8');
          expect(advert.paymentMethod, PaymentMethod.bankTransfer);
          expect(advert.type, TransactionType.sell);

          final P2PAdvertiser advertiser = order.advertiserDetails;
          expect(advertiser.id, '6');
          expect(advertiser.name, 'advertiser CR90000018');

          expect(
            order.subscriptionInformation.id,
            '857cfc96-1014-66ce-9c49-0a4dbd22857a',
          );
        },
      ));
    });
  });
}
