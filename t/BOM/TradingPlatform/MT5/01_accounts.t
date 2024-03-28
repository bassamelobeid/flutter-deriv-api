use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::More;
use Test::Deep;
use Test::MockModule;
use Test::Exception;
use BOM::TradingPlatform;

use Array::Utils qw(array_minus);

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

subtest 'available_accounts _get_mt5_lc_requirements' => sub {
    subtest 'returns only missing signup requirements' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'ke'
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

        my $available_accounts = $mt5->available_accounts({country_code => $client->residence});

        for my $account ($available_accounts->@*) {
            my $lc_short = $account->{shortcode};
            my $lc       = LandingCompany::Registry->by_name($lc_short);

            my @satisfied_requirements =
                ('salutation', 'first_name', 'last_name', 'date_of_birth', 'address_line_1', 'residence', 'phone', 'address_city', 'citizen');

            my @signup_requirements = array_minus($lc->requirements->{signup}->@*, @satisfied_requirements);

            cmp_deeply $account->{requirements}->{signup}, \@signup_requirements,
                "signup requirements for $lc_short contain only missings requirements";
        }
    };

    subtest 'returns only missing signup requirements' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'ar'
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

        lives_ok { $client->tax_residence('ar') } 'client satisfies tax_residence requirement';

        my $available_accounts = $mt5->available_accounts({country_code => $client->residence});

        for my $account ($available_accounts->@*) {
            my $lc_short = $account->{shortcode};
            my $lc       = LandingCompany::Registry->by_name($lc_short);

            my @satisfied_requirements = (
                'salutation', 'first_name',   'last_name', 'date_of_birth', 'address_line_1', 'residence',
                'phone',      'address_city', 'citizen',   'tax_residence'
            );

            my @signup_requirements = array_minus($lc->requirements->{signup}->@*, @satisfied_requirements);

            cmp_deeply $account->{requirements}->{signup}, \@signup_requirements,
                "signup requirements for $lc_short contain only missings requirements";
        }
    };

    subtest 'returns physical address as missing signup requirement if client has po box address' => sub {
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

        $client->address_1('po box 123');
        $client->save;

        ok BOM::User::Utility::has_po_box_address($client), 'client has po box as address';

        my $available_accounts = $mt5->available_accounts({country_code => $client->residence});

        for my $account ($available_accounts->@*) {
            my $lc_short = $account->{shortcode};
            my $lc       = LandingCompany::Registry->by_name($lc_short);

            my @satisfied_requirements =
                ('salutation', 'first_name', 'last_name', 'date_of_birth', 'address_line_1', 'residence', 'phone', 'address_city', 'citizen');

            my @signup_requirements = array_minus($lc->requirements->{signup}->@*, @satisfied_requirements);
            push @signup_requirements, 'physical_address' if $lc->physical_address_required;

            cmp_deeply $account->{requirements}->{signup}, \@signup_requirements,
                "signup requirements for $lc_short contain only missings requirements, MT5 account signup requires physical address";
        }
    };
};

done_testing();
