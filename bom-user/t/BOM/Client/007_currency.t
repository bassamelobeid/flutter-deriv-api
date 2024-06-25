use strict;
use warnings;
use Test::More;
use Test::MockModule;
use BOM::User::Client;
use BOM::User;

subtest 'Virtual Account' => sub {
    my $test_client_vr = BOM::User::Client->rnew(
        broker_code => 'VRTC',
        residence   => 'br',
        citizen     => 'br',
        email       => 'nowthatsan@email.com',
        loginid     => 'VRTC235711'
    );

    ok $test_client_vr->is_virtual, 'We got a virtual account';
    is $test_client_vr->currency, 'USD', 'Virtual default currency is USD';

    subtest 'Manipulate LC config' => sub {
        # BTC as default currency
        my $mock_lc = Test::MockModule->new(ref($test_client_vr->landing_company({business_rules => 1})));
        $mock_lc->mock(
            'legal_default_currency',
            sub {
                return 'BTC';
            });

        is $test_client_vr->currency, 'BTC', 'Virtual default currency is BTC';

        # Martian USD for martian residents
        my $mock_client = Test::MockModule->new(ref($test_client_vr));
        $mock_client->mock(
            'residence',
            sub {
                return 'mars';
            });
        $mock_lc->mock(
            'residences_default_currency',
            sub {
                return {
                    mars => 'USDM',    # Martian USD ?
                };
            });

        is $test_client_vr->currency, 'USDM', 'Martian default currency is USDM';
        $mock_lc->unmock_all;
        $mock_client->unmock_all;
    };
};

subtest 'Australian SVG Account' => sub {
    my $test_client_au = BOM::User::Client->rnew(
        broker_code => 'CR',
        residence   => 'au',
        citizen     => 'au',
        email       => 'nowthatsan@email.com',
        loginid     => 'CR235711'
    );

    is $test_client_au->landing_company->short, 'svg', 'We got a SVG account';
    is $test_client_au->currency,               'USD', 'Australian svg account default currency is USD';

    subtest 'Australian Non-SVG Account' => sub {
        $test_client_au = BOM::User::Client->rnew(
            broker_code => 'MF',
            residence   => 'au',
            citizen     => 'au',
            email       => 'nowthatsan@email.com',
            loginid     => 'MF235711'
        );

        ok $test_client_au->landing_company->short ne 'svg', 'We got a non-SVG account';
        is $test_client_au->currency, $test_client_au->landing_company->legal_default_currency,
            'Australian non-svg account default currency is the LC default currency';
    };

};

done_testing();
