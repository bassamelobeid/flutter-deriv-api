use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::Warnings;

use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::MT5::User::Async;
use BOM::Rules::Engine;
use BOM::TradingPlatform;
use BOM::Test::Script::DevExperts;
use BOM::Config::Runtime;
use BOM::Test::Helper::P2PWithClient;
use BOM::User::WalletMigration;

plan tests => 13;

BOM::Test::Helper::P2PWithClient::bypass_sendbird();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->system->suspend->wallets(0);
$app_config->system->suspend->wallet_migration(0);

subtest 'Suspend runtime settings' => sub {
    my ($user) = create_user();

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $client_cr->set_default_account('USD');
    $user->add_client($client_cr);

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok $migration->is_eligible(no_cache => 1), 'User is eligible at first';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], [], 'no failed checks';

    $app_config->system->suspend->wallets(1);
    ok !$migration->is_eligible(no_cache => 1), 'User not eligible when wallets suspended';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['wallets_suspended'], 'failed checks is wallets_suspended';

    $app_config->system->suspend->wallets(0);
    $app_config->system->suspend->wallet_migration(1);

    ok !$migration->is_eligible(no_cache => 1), 'User not eligible when migration suspended';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['wallet_migration_suspended'], 'failed checks is wallet_migration_suspended';

    $app_config->system->suspend->wallet_migration(0);
};

subtest 'Country eligibility' => sub {
    # Only available for aq (antarctica) for now
    my @test_cases = ({
            country => 'aq',
            result  => 1
        },
        {
            country => '',
            result  => 0
        },
        {
            country => 'id',
            result  => 0
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
        my ($user) = create_user($test_case->{country});

        my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => $test_case->{country},
        });

        $client_cr->set_default_account('USD');
        $user->add_client($client_cr);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        is $migration->is_eligible(no_cache => 1) // 0, $test_case->{result},
            'Eligibility for ' . ($test_case->{country} || 'none') . ' is ' . $test_case->{result};
        my $checks = $test_case->{result} ? [] : ['unsupported_country'];
        cmp_deeply [$migration->eligibility_checks(no_cache => 1)], $checks, 'Failed checks for ' . ($test_case->{country} || 'none');
    }

    subtest 'multiple residences, one invalid' => sub {
        my ($user) = create_user();

        my $client_aq = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'aq',
        });
        $client_aq->set_default_account('USD');
        $user->add_client($client_aq);

        my $client_id = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'id',
        });
        $client_id->set_default_account('BTC');
        $user->add_client($client_id);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['unsupported_country'], 'fail if one country is invalid';
    };

    subtest 'multiple residences, one empty' => sub {
        my ($user) = create_user();

        my $client_aq = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'aq',
        });
        $client_aq->set_default_account('USD');
        $user->add_client($client_aq);

        my $client_none = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => '',
        });
        $client_none->set_default_account('BTC');
        $user->add_client($client_none);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        cmp_deeply [$migration->eligibility_checks(no_cache => 1)], [], 'no fail for an empty country and valid one';
    };
};

subtest 'checks for SVG USD real account and non MF' => sub {
    my ($user) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok !$migration->is_eligible(no_cache => 1), 'No real account not eligible';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], bag(qw(no_real_account no_svg_usd_account)), 'Failed checks for no real account';

    my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $client_btc->set_default_account('BTC');
    $user->add_client($client_btc);

    ok !$migration->is_eligible(no_cache => 1), 'Not eligible with only crypto';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['no_svg_usd_account'], 'Failed checks with only crypto';

    my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $user->add_client($client_usd);
    $client_usd->set_default_account('USD');

    # reset cached clients
    $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok $migration->is_eligible(no_cache => 1), 'Eligible with USD real account';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], [], 'No failed checks with USD real account';

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
        residence   => 'aq',
    });

    $client_mf->set_default_account('USD');
    $user->add_client($client_mf);

    ok !$migration->is_eligible(no_cache => 1), 'Not eligible with MF account';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['has_non_svg_real_account'], 'Failed checks with MF real account';
};

subtest 'currency not set' => sub {

    my ($user) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $client1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $user->add_client($client1);

    ok !$migration->is_eligible(no_cache => 1), 'Not eligible with no currency set';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], bag('currency_not_set', 'no_svg_usd_account'),
        'Failed checks is currency_not_set and no_svg_usd_account';

    $client1->set_default_account('USD');

    # reset client cache
    $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok $migration->is_eligible(no_cache => 1), 'Eligible after setting currency';

    my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $user->add_client($client2);

    ok !$migration->is_eligible(no_cache => 1), 'Not eligible after adding sibling with no currency set';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['currency_not_set'], 'Failed checks is currency_not_set';

};

subtest 'EUR account' => sub {
    my ($user) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $client_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $client_eur->set_default_account('EUR');
    $user->add_client($client_eur);

    ok !$migration->is_eligible(no_cache => 1), 'Not eligible with EUR account';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['no_svg_usd_account'], 'Failed checks with EUR account';
};

subtest 'p2p' => sub {
    my ($user) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $client->set_default_account('USD');
    $user->add_client($client);

    ok $migration->is_eligible(no_cache => 1), 'Eligible at first';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], [], 'No failed checks at first';

    $client->p2p_advertiser_create(name => 'x');

    ok !$migration->is_eligible(no_cache => 1), 'Not eligible after registering for p2p';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['registered_p2p'], 'Failed checks is registered_p2p';
};

subtest 'payment agent' => sub {
    my ($user) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $client->set_default_account('USD');
    $user->add_client($client);

    ok $migration->is_eligible(no_cache => 1), 'Eligible at first';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], [], 'No failed checks at first';

    $client->payment_agent({
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
    $client->save();

    $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok !$migration->is_eligible(no_cache => 1), 'Not eligible after becoming pa';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['registered_pa'], 'Failed checks is registered_pa';
};

subtest 'join date' => sub {
    my ($user, $vr_client) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $client->set_default_account('USD');
    $user->add_client($client);

    $client->date_joined(Date::Utility->new->minus_time_interval('89d')->db_timestamp);
    $client->save;

    ok !$migration->is_eligible(no_cache => 1), 'Not eligibile with recent join date';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['invalid_join_date'], 'Failed checks is invalid_join_date';

    $client->date_joined(Date::Utility->new->minus_time_interval('90d')->db_timestamp);
    $client->save;

    # reset client cache
    $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok $migration->is_eligible(no_cache => 1), 'Eligibile with 90 day join date';
};

subtest 'skip joining date check of internal staff who are using company email' => sub {
    my @emails = ('newbie@deriv.com', 'newbie@regentmarkets.com');

    for my $email (@emails) {
        my ($user, $vr_client) = create_user('aq', $email);

        my $migration = BOM::User::WalletMigration->new(
            user   => $user,
            app_id => 1,
        );

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'aq',
        });

        $client->set_default_account('USD');
        $user->add_client($client);

        $client->date_joined(Date::Utility->new->minus_time_interval('89d')->db_timestamp);
        $client->save;

        ok $migration->is_eligible(no_cache => 1), "It should be eligible with recent join date for $email";
    }
};

subtest 'payment agent transactions' => sub {
    my ($user) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $client->set_default_account('USD');
    $user->add_client($client);

    ok $migration->is_eligible(no_cache => 1), 'Eligible at first';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], [], 'No failed checks at first';

    $client->default_account->add_payment_transaction({
        amount               => 1,
        payment_gateway_code => 'payment_agent_transfer',
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $client->loginid,
        remark               => 'test',
        source               => 1,
    });

    ok !$migration->is_eligible(no_cache => 1), 'Not eligible with pa transfer';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['has_used_pa'], 'Failed checks is has_used_pa';

    $client->default_account->add_payment_transaction({
        amount               => -1,
        payment_gateway_code => 'payment_agent_transfer',
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => $client->loginid,
        remark               => 'test',
        source               => 1,
    });

    ok !$migration->is_eligible(no_cache => 1), 'Not eligible with net zero pa transactions';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], ['has_used_pa'], 'Failed checks is has_used_pa';
};

subtest 'disabled or duplicate account not eligible' => sub {
    my ($user) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $client->set_default_account('USD');
    $user->add_client($client);

    ok $migration->is_eligible(no_cache => 1), 'Eligible at first';
    cmp_deeply [$migration->eligibility_checks(no_cache => 1)], [], 'No failed checks at first';

    $client->status->set('disabled', 'system', 'for testing');

    my $migration1 = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok !$migration1->is_eligible(no_cache => 1), 'Not eligible for disabled account';
    cmp_deeply [$migration1->eligibility_checks(no_cache => 1)], ['no_duplicate_or_disabled_account'], 'Failed checks is no_dup_or_disabled_account';

    $client->status->_clear('disabled');

    my $migration2 = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok $migration2->is_eligible(no_cache => 1), 'Eligible at first';
    cmp_deeply [$migration2->eligibility_checks(no_cache => 1)], [], 'No failed checks at first';

    $client->status->set('duplicate_account', 'system', 'for testing');

    my $migration3 = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    ok !$migration3->is_eligible(no_cache => 1), 'Not eligible for duplicate account';
    cmp_deeply [$migration3->eligibility_checks(no_cache => 1)], ['no_duplicate_or_disabled_account'], 'Failed checks is no_dup_or_disabled_account';
};

subtest 'skip joining date check for internal client' => sub {
    my ($user, $vr_client) = create_user();

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'aq',
    });

    $client->set_default_account('USD');
    $user->add_client($client);

    $client->date_joined(Date::Utility->new->minus_time_interval('89d')->db_timestamp);
    $client->save;
    $client->status->set('internal_client', 'system', 'for testing');

    ok $migration->is_eligible(no_cache => 1), 'Will be eligibile with recent join date because of internal client status';
};

my $user_counter = 1;

sub create_user {
    my $residence = shift;
    my $email     = shift;

    my $user = BOM::User->create(
        email    => $email // 'testuser' . $user_counter++ . '@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        residence   => $residence // 'aq',
    });

    $client_virtual->set_default_account('USD');

    $user->add_client($client_virtual);

    return ($user, $client_virtual);
}

done_testing();
