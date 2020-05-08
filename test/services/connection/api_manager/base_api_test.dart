import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_deriv_api/services/connection/api_manager/base_api.dart';
import 'package:flutter_deriv_api/services/connection/api_manager/mock_api.dart';
import 'package:flutter_deriv_api/services/dependency_injector/injector.dart';
import 'package:flutter_deriv_api/services/dependency_injector/module_container.dart';

void main() {
  test('base api test', () async {
    ModuleContainer().initialize(Injector.getInjector(), isMock: true);

    expect(Injector.getInjector().get<BaseAPI>() is MockAPI, true);
  });
}
