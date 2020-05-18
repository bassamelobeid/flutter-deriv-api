import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_deriv_api/api/account/top_up_virtual/top_up_virtual.dart';
import 'package:flutter_deriv_api/services/dependency_injector/injector.dart';
import 'package:flutter_deriv_api/services/dependency_injector/module_container.dart';

void main() {
  test('top up virtual', () async {
    ModuleContainer().initialize(Injector.getInjector(), isMock: true);

    final TopUpVirtual topUpVirtual = await TopUpVirtual.topUp();

    expect(topUpVirtual.amount, 30.0);
    expect(topUpVirtual.currency, 'USD');
  });
}
