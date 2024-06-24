use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::More;
use Test::Deep;
use Test::MockModule;
use Test::Exception;
use BOM::TradingPlatform;
use Brands;

use List::Util      qw(uniq);
use Array::Utils    qw(array_minus);
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);

# List of mt5 accounts
my %mt5_account = (
    demo  => {login => 'MTD1000'},
    real  => {login => 'MTR1000'},
    real2 => {login => 'MTR40000000'},
);

subtest 'check if mt5 trading platform get_accounts will return the correct user' => sub {
    # Creating the account
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $user   = BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $user->add_loginid($mt5_account{demo}{login});
    $user->add_loginid($mt5_account{real}{login});
    $user->add_loginid($mt5_account{real2}{login});

    # Check for MT5 TradingPlatform
    my $mt5 = BOM::TradingPlatform->new(
        platform => 'mt5',
        client   => $client
    );
    isa_ok($mt5, 'BOM::TradingPlatform::MT5');

    # We need to mock the module to get a proper response
    my $mock_mt5           = Test::MockModule->new('BOM::TradingPlatform::MT5');
    my @check_mt5_accounts = ($mt5_account{demo}{login}, $mt5_account{real}{login}, $mt5_account{real2}{login});
    $mock_mt5->mock('get_accounts', sub { return Future->done(\@check_mt5_accounts); });

    cmp_deeply($mt5->get_accounts->get, \@check_mt5_accounts, 'can get accounts using get_accounts');

    $mock_mt5->unmock_all();
};

subtest 'MT5 regulated account availability' => sub {
    subtest 'accounts are not available for client from PJ for the MT5 company if no tin' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'za'
        });

        my $user = BOM::User->create(
            email    => $client->loginid . '@deriv.com',
            password => 'secret_pwd',
        )->add_client($client);

        my $mt5 = BOM::TradingPlatform->new(
            platform    => 'mt5',
            client      => $client,
            rule_engine => BOM::Rules::Engine->new(client => $client));

        isa_ok($mt5, 'BOM::TradingPlatform::MT5');

        my $mock_npj_jurisdictions = {
            bvi         => ['za'],
            labuan      => ['za'],
            vanuatu     => ['za'],
            maltainvest => ['za'],
            svg         => ['za']};

        my $mock_compliance = Test::MockModule->new('BOM::Config::Compliance');
        $mock_compliance->mock(
            'is_tin_required',
            sub {
                my ($self, $lc_short, $country) = @_;

                my $result = !grep { $country eq $_ } $mock_npj_jurisdictions->{$lc_short}->@*;

                return $result;
            });

        ok !$client->tax_identification_number, 'client does not have tax_identification_number';

        my $available_accounts = $mt5->available_accounts({country_code => $client->residence, brand => Brands->new});
        my $accounts           = [uniq(map { $_->{shortcode} } $available_accounts->@*)];

        my $expected_accounts = ['svg', 'bvi', 'vanuatu', 'maltainvest', 'labuan'];
        cmp_deeply $accounts, $expected_accounts, 'expected available accounts for npj country for mt5 jurisdiction';

        delete $mock_npj_jurisdictions->{bvi};
        delete $mock_npj_jurisdictions->{vanuatu};
        delete $mock_npj_jurisdictions->{maltainvest};

        $available_accounts = $mt5->available_accounts({country_code => $client->residence, brand => Brands->new});
        $accounts           = [uniq(map { $_->{shortcode} } $available_accounts->@*)];

        $expected_accounts = ['svg', 'labuan'];
        cmp_deeply $accounts, $expected_accounts, 'expected available accounts when residence country is pj for bvi';

        lives_ok { $client->tax_identification_number('123') } 'client has tax_identification_number';

        $available_accounts = $mt5->available_accounts({country_code => $client->residence, brand => Brands->new});
        $accounts           = [uniq(map { $_->{shortcode} } $available_accounts->@*)];

        $expected_accounts = ['svg', 'bvi', 'vanuatu', 'maltainvest', 'labuan'];
        cmp_deeply $accounts, $expected_accounts, 'if client has tax_identification_number, all accounts are available again';

        lives_ok { $client->tax_identification_number(undef) } 'client does not have tax_identification_number';

        $client->tin_approved_time(Date::Utility->new()->date_yyyymmdd);
        $client->save();

        ok $client->is_tin_manually_approved, 'client is tin_manually_approved';

        $available_accounts = $mt5->available_accounts({country_code => $client->residence, brand => Brands->new});
        $accounts           = [uniq(map { $_->{shortcode} } $available_accounts->@*)];

        $expected_accounts = ['svg', 'bvi', 'vanuatu', 'maltainvest', 'labuan'];
        cmp_deeply $accounts, $expected_accounts, 'if client is tin_manually_approved, all accounts are available again';

        $mock_compliance->unmock_all();
    };

    subtest 'accounts are not available for client with po box address' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
            residence   => 'za'
        });

        my $user = BOM::User->create(
            email    => $client->loginid . '@deriv.com',
            password => 'secret_pwd'
        )->add_client($client);

        my $mt5 = BOM::TradingPlatform->new(
            platform    => 'mt5',
            client      => $client,
            rule_engine => BOM::Rules::Engine->new(client => $client));

        isa_ok($mt5, 'BOM::TradingPlatform::MT5');

        # this condition is already tested in the previous subtest
        my $mock_compliance = Test::MockModule->new('BOM::Config::Compliance');
        $mock_compliance->mock('is_tin_required', sub { return 0 });

        my $available_accounts = $mt5->available_accounts({country_code => $client->residence, brand => Brands->new});
        my $accounts           = [uniq(map { $_->{shortcode} } $available_accounts->@*)];

        my $expected_accounts = ['svg', 'bvi', 'vanuatu', 'maltainvest', 'labuan'];
        cmp_deeply $accounts, $expected_accounts, 'expected available accounts';

        $client->set_authentication('ID_PO_BOX', {status => 'pass'});
        ok $client->is_po_box_verified(), 'client is fully authenticated and has po box as address';

        $available_accounts = $mt5->available_accounts({country_code => $client->residence, brand => Brands->new});
        $accounts           = [uniq(map { $_->{shortcode} } $available_accounts->@*)];

        $expected_accounts = ['svg'];
        cmp_deeply $accounts, $expected_accounts, 'MT5 accounts not available for client with po box address';

        $mock_compliance->unmock_all();
    };
};

done_testing();
