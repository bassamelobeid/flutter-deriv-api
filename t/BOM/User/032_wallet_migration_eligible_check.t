use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Fatal;
use Test::Warnings;

use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::MT5::User::Async;
use BOM::Rules::Engine;
use BOM::TradingPlatform;
use BOM::Test::Script::DevExperts;

use BOM::User::WalletMigration;

use BOM::Config::Runtime;

use BOM::Test::Helper::P2P;

plan tests => 6;

BOM::Test::Helper::P2P::bypass_sendbird();

subtest 'Eligibility check' => sub {
    # TODO: This is place holder for future tests when we'll start adding logic to this method
    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

    my ($user) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok(!$migration->is_eligible, 'Should return false if client is not eligible for migration');

};

subtest 'check_eligibility_for_country' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

    my $countries_mock = Test::MockModule->new('Brands::Countries');
    $countries_mock->mock(
        wallet_companies_for_country => sub {
            (undef, my $country_code, my $type) = @_;
            my %mock_data = (
                id => {
                    virtual => [qw(virtual)],
                    real    => [qw(svg)],
                },
                es => {
                    virtual => [qw(virtual)],
                    real    => [qw(maltainvest)],
                },
                za => {
                    virtual => [qw(virtual)],
                    real    => [qw(maltainvest svg)],
                },
                my => {
                    virtual => [qw(virtual)],
                    real    => [],
                },
            );

            return $mock_data{$country_code}{$type} // [];
        });

    my ($user) = create_user();
    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    # Should be eligible for all svg enbled countries countries as part of phase 1
    my @test_cases = ({
            country => 'id',
            result  => 1
        },
        {
            country => 'es',
            result  => 0
        },
        {
            country => 'za',
            result  => 0
        },
        {
            country => 'ru',
            result  => 0
        },
        {
            country => 'my',
            result  => 0
        },
    );

    ok(@test_cases > 0, 'Should have at least one test case');
    for my $test_case (@test_cases) {
        is($migration->check_eligibility_for_country($test_case->{country}),
            $test_case->{result}, 'Should return correct result for country ' . $test_case->{country});
    }
};

subtest check_eligibility_for_usd_dtrade_account => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

    my ($user, $client_virtual) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        date_joined => Date::Utility->new->datetime_yyyymmdd_hhmmss,
    });

    $cr_usd->set_default_account('USD');
    $user->add_client($cr_usd);

    my $res = $migration->check_eligibility_for_usd_dtrade_account($cr_usd);

    ok(!$res, 'The client that joined us less than 3 months ago should not be eligible for migration');

    my $date_before_threshold = time - (60 * 60 * 24 * BOM::User::WalletMigration::ELIGIBILITY_THRESHOLD_IN_DAYS + 1);
    $cr_usd->date_joined(Date::Utility->new($date_before_threshold)->datetime_yyyymmdd_hhmmss);
    $cr_usd->save();

    $res = $migration->check_eligibility_for_usd_dtrade_account($cr_usd);

    ok($res, 'The client that joined us more than 3 months ago should be eligible for migration');

    $cr_usd->p2p_advertiser_create(name => 'TestAdvertiserForWalletMigration');

    $res = $migration->check_eligibility_for_usd_dtrade_account($cr_usd);

    ok(!$res, 'The client that created P2P advertiser should not be eligible for migration');
};

subtest check_eligibility_for_real_dtrade_accounts => sub {
    my $countries_mock = Test::MockModule->new('Brands::Countries');
    $countries_mock->mock(
        wallet_companies_for_country => sub {
            (undef, my $country_code, my $type) = @_;
            my %mock_data = (
                id => {
                    virtual => [qw(virtual)],
                    real    => [qw(svg)],
                });

            return $mock_data{$country_code}{$type} // [];
        });

    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);

    subtest 'Checking eligibility for USD account' => sub {
        my ($user, $client_virtual) = create_user();

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $res = $migration->check_eligibility_for_real_dtrade_accounts();

        ok(!$res, 'The client that has no real dtrade accounts should not be eligible for migration');

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'id',
            date_joined => Date::Utility->new->datetime_yyyymmdd_hhmmss,
        });

        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        $res = $migration->check_eligibility_for_real_dtrade_accounts();

        ok(!$res, 'The client that has joined less than 90 days ago should be not eligible for migration');

        my $date_before_threshold = time - (60 * 60 * 24 * BOM::User::WalletMigration::ELIGIBILITY_THRESHOLD_IN_DAYS + 1);
        $cr_usd->date_joined(Date::Utility->new($date_before_threshold)->datetime_yyyymmdd_hhmmss);
        $cr_usd->save();

        $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok($res, 'The client that has joined more than 90 days ago should be eligible for migration');

    };

    subtest 'Checking eligibility for USD+BTC account' => sub {
        my ($user, $client_virtual) = create_user();

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'id'
        });

        $cr_btc->set_default_account('BTC');
        $user->add_client($cr_btc);

        my $res = $migration->check_eligibility_for_real_dtrade_accounts();

        ok(!$res, 'The clients with just BTC account should be not eligible for migration');

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'id',
        });

        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok($res, 'The clients with just BTC account should be not eligible for migration');
    };

    subtest 'Checking eligibility if client has payment agent transactions' => sub {
        my ($user, $client_virtual) = create_user();

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'id',
        });

        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok($res, 'The clients is eligible with no payment agent transactions');

        $cr_usd->default_account->add_payment_transaction({
                amount               => 1,
                payment_gateway_code => 'payment_agent_transfer',
                payment_type_code    => 'internal_transfer',
                status               => 'OK',
                staff_loginid        => $cr_usd->loginid,
                remark               => 'test',
                account_id           => $cr_usd->default_account->id,
                source               => 1,
            },
            undef,
            {});

        $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok(!$res, 'The clients is not eligible with payment agent transactions');

        $cr_usd->default_account->add_payment_transaction({
                amount               => -1,
                payment_gateway_code => 'payment_agent_transfer',
                payment_type_code    => 'internal_transfer',
                status               => 'OK',
                staff_loginid        => $cr_usd->loginid,
                remark               => 'test',
                account_id           => $cr_usd->default_account->id,
                source               => 1,
            },
            undef,
            {});

        $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok(!$res, 'The clients is not eligible with payment agent transactions that has net amount 0');
    };

    subtest 'Checking eligibility if all clients has currency selected' => sub {
        my ($user, $client_virtual) = create_user();

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'id',
        });

        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok($res, 'The clients is eligible with just USD account');

        my $cr_no_currency = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'id'
        });

        $user->add_client($cr_no_currency);

        $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok(!$res, 'The clients is not eligible with no currency selected');

        $cr_no_currency->set_default_account('ETH');

        $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok($res, 'After selecting currency the client is eligible');
    };

    subtest 'Checking eligibility if the client is a payment agent' => sub {
        my ($user, $client_virtual) = create_user();

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'id',
        });

        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok($res, 'The clients is eligible with just USD account');

        $cr_usd->payment_agent({
            payment_agent_name    => 'Joe 3',
            email                 => 'joe@example.com',
            information           => 'Test Info',
            summary               => 'Test Summary',
            commission_deposit    => 0,
            commission_withdrawal => 0,
            status                => 'authorized',
            currency_code         => 'USD',
            is_listed             => 'f',
        });
        $cr_usd->save();

        $res = $migration->check_eligibility_for_real_dtrade_accounts();
        ok(!$res, 'If client is a payment agent it should not be eligible for migration');
    };
};

subtest 'check_eligibility_for_user' => sub {
    my ($user, $client_virtual) = create_user();
    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $res = $migration->check_eligibility_for_user();

    ok(!$res, 'The client that has no real dtrade accounts should not be eligible for migration');

    my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id',
    });

    $user->add_client($cr_usd);

    $res = $migration->check_eligibility_for_user();

    ok($res, 'The client that has real dtrade accounts should be eligible for migration');
};

my $user_counter = 1;

sub create_user {
    my $user = BOM::User->create(
        email    => 'testuser' . $user_counter++ . '@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');

    $user->add_client($client_virtual);

    return ($user, $client_virtual);
}

done_testing();
