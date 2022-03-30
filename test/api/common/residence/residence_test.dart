import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_deriv_api/api/api_initializer.dart';
import 'package:flutter_deriv_api/api/common/residence/residence.dart';

void main() {
  setUp(() => APIInitializer().initialize(isMock: true));

  test('Fetch Residence List Test', () async {
    final List<Residence?>? residenceList =
        await Residence.fetchResidenceList();

    final Residence firstResidence = residenceList!.first!;

    expect(firstResidence.countryName, 'SampleCountry');
    expect(firstResidence.countryCode, 'sc');
    expect(firstResidence.phoneIdd, '00');
    expect(firstResidence.disabled, 'DISABLED');
    expect(firstResidence.isDisabled, true);
    expect(firstResidence.isSelected, false);
    expect(residenceList.length, 1);
  });
}
