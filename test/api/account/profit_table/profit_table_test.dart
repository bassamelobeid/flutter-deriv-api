import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_deriv_api/api/account/models/profit_transaction_model.dart';
import 'package:flutter_deriv_api/api/account/profit_table/profit_table.dart';
import 'package:flutter_deriv_api/api/api_initializer.dart';
import 'package:flutter_deriv_api/basic_api/generated/api.dart';
import 'package:flutter_deriv_api/utils/helpers.dart';

void main() {
  setUp(() => APIInitializer().initialize(true));

  test('Fetch Profit Table Test', () async {
    final ProfitTable profitTable = await ProfitTable.fetch(
      const ProfitTableRequest(
        description: true,
        limit: 25,
        offset: 25,
        sort: 'ASC',
      ),
    );

    expect(profitTable.count, 1);

    expect(profitTable.transactions.length, 1);

    final ProfitTransactionModel transaction = profitTable.transactions.first;

    expect(transaction.appId, 1234);
    expect(transaction.buyPrice, 250.0);
    expect(transaction.contractId, 4867502908);
    expect(
      transaction.longCode,
      'Win payout if Volatility 10 (1s) Index after 5 ticks is strictly higher than entry spot.',
    );
    expect(transaction.payout, 10.0);
    expect(transaction.purchaseTime, getDateTime(1587544006));
    expect(transaction.sellPrice, 5.25);
    expect(transaction.sellTime, getDateTime(1587554006));
    expect(transaction.shortCode, 'CALL_1HZ10V_1.95_1589779082_5T_S0P_0');
    expect(transaction.transactionId, 10867502908);
  });
}
