use strict;
use warnings;

use Test::MockModule;
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use Business::Config::Account;
use BOM::User::Client;

subtest 'get limit for payout' => sub {
    my $tests     = ['BCH', 'USD', 'DOGE', 'BTC', 'ADA'];
    my $positions = {
        USD => 100,
        BTC => 20000,
    };
    my $currency;

    my $client_mock = Test::MockModule->new('BOM::User::Client');
    $client_mock->mock(
        'currency',
        sub {
            $currency;
        });

    my $config_mock = Test::MockModule->new('Business::Config::Account');
    $config_mock->mock(
        'limit',
        sub {
            return {max_payout_open_positions => $positions};
        });

    for ($tests->@*) {
        subtest $_ => sub {
            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });

            $currency = $_;

            ok defined $client->get_limit_for_payout, 'Defined limit for payout';

            is $client->get_limit_for_payout, $positions->{$currency}, $currency . ' has the expected value' if defined $positions->{$currency};

            is $client->get_limit_for_payout, 0, $currency . ' defaulted to 0' unless defined $positions->{$currency};
        };
    }

    $client_mock->unmock_all;
    $config_mock->unmock_all;
};

subtest 'get limit for account balance' => sub {
    my $tests = [{
            currency       => 'USD',
            self_exclusion => 20,
            virtual        => 1,
            result         => 10,
            test           => 'USD Virtual configured min'
        },
        {
            currency       => 'BTC',
            self_exclusion => 1,
            virtual        => 0,
            result         => 1,
            test           => 'BTC Real self exclusion min'
        },
        {
            currency       => 'USD',
            self_exclusion => 5,
            virtual        => 0,
            result         => 5,
            test           => 'USD Real self exclusion min'
        },
        {
            currency       => 'BTC',
            self_exclusion => undef,
            virtual        => 0,
            result         => 1000,
            test           => 'BTC Virtual configured min'
        },
        {
            currency       => 'DOGE',
            self_exclusion => 1,
            virtual        => 0,
            result         => 1,
            test           => 'Doge Real self exclusion min'
        },
        {
            currency       => 'DOGE',
            self_exclusion => undef,
            virtual        => 0,
            result         => 0,
            test           => 'Doge Real with undefined self exlusion is zero'
        },
        {
            currency       => 'BCH',
            self_exclusion => undef,
            virtual        => 1,
            result         => 0,
            test           => 'BCH Virtual with undefined self exlusion is zero'
        },
        {
            currency       => 'BCH',
            self_exclusion => 900,
            virtual        => 1,
            result         => 900,
            test           => 'BCH Virtual self exclusion min'
        }];

    my $max_balance = {
        virtual => {
            USD => 10,
            BTC => 50,
        },
        real => {
            USD => 100,
            BTC => 1000,
        }};

    my $currency;
    my $self_exclusion;

    my $client_mock = Test::MockModule->new('BOM::User::Client');
    $client_mock->mock(
        'currency',
        sub {
            $currency;
        });
    $client_mock->mock(
        'get_self_exclusion',
        sub {
            bless({max_balance => $self_exclusion}, 'BOM::Database::AutoGenerated::Rose::SelfExclusion');
        });

    my $config_mock = Test::MockModule->new('Business::Config::Account');
    $config_mock->mock(
        'limit',
        sub {
            return {max_balance => $max_balance};
        });

    for ($tests->@*) {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => $_->{virtual} ? 'VRTC' : 'CR',
        });

        $currency       = $_->{currency};
        $self_exclusion = $_->{self_exclusion};

        if ($client->landing_company->unlimited_balance && !$self_exclusion) {
            is $client->get_limit_for_account_balance, 0, $_->{test};
        } else {
            is $client->get_limit_for_account_balance, $_->{result}, $_->{test};
        }
    }

    $client_mock->unmock_all;
    $config_mock->unmock_all;
};

done_testing;
