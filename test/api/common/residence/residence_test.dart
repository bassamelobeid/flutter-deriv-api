import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_deriv_api/api/api_initializer.dart';
import 'package:flutter_deriv_api/api/common/residence/residence.dart';

void main() {
  setUp(() => APIInitializer().initialize(true));

  test('Fetch Residence List Test', () async {
    final List<Residence> residenceList = await Residence.fetchResidenceList();

    expect(residenceList.first.countryName, 'SampleCountry');
    expect(residenceList.first.countryCode, 'sc');
    expect(residenceList.first.phoneIdd, '00');
    expect(residenceList.first.disabled, 'DISABLED');
    expect(residenceList.first.isDisabled, true);
    expect(residenceList.first.isSelected, false);
    expect(residenceList.length, 1);
  });
}
