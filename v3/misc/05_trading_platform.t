use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use BOM::Test::Helper::Client;
use await;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Platform::Token::API;
use BOM::Platform::Token;
use BOM::Database::Model::OAuth;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Guard;

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

# We need to restore previous values when tests is done
my %init_config_values = (
    'system.dxtrade.suspend.all' => $app_config->system->dxtrade->suspend->all,
);

scope_guard {
    for my $key (keys %init_config_values) {
        $app_config->set({$key => $init_config_values{$key}});
    }
};

$app_config->set({'system.dxtrade.suspend.all' => 0});

my $t = build_wsapi_test();

my $client1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

my $user = BOM::User->create(
    email    => $client1->email,
    password => 'test'
);

$user->add_client($client1);
$user->add_client($client2);
$client1->account('USD');
$client2->account('USD');

my $client1_token_read     = BOM::Platform::Token::API->new->create_token($client1->loginid, 'test token', ['read']);
my $client1_token_admin    = BOM::Platform::Token::API->new->create_token($client1->loginid, 'test token', ['admin']);
my $client1_token_payments = BOM::Platform::Token::API->new->create_token($client1->loginid, 'test token', ['payments']);
my $client2_token_payments = BOM::Platform::Token::API->new->create_token($client2->loginid, 'test token', ['payments']);
my ($client1_token_oauth)  = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client1->loginid);

my $dx_acc;
my $dx_syn;

subtest 'accounts' => sub {

    my $params = {
        trading_platform_new_account => 1,
        platform                     => 'dxtrade',
        account_type                 => 'real',
        market_type                  => 'financial',
        password                     => 'Test1234',
    };

    $t->await::authorize({authorize => $client1_token_read});
    my $res = $t->await::trading_platform_new_account($params);
    is $res->{error}{code}, 'PermissionDenied', 'cannot create account with read scope';

    $t->await::authorize({authorize => $client1_token_admin});
    $res = $t->await::trading_platform_new_account($params);
    is $res->{error}, undef, 'No error';
    ok $res->{trading_platform_new_account}{account_id}, 'create account successfully';
    test_schema('trading_platform_new_account', $res);
    $dx_acc = $res->{trading_platform_new_account};

    $params->{market_type} = 'synthetic';
    $t->await::authorize({authorize => $client1_token_admin});
    $res = $t->await::trading_platform_new_account($params);
    is $res->{error}, undef, 'No error';
    ok $res->{trading_platform_new_account}{account_id}, 'create gaming account successfully';
    test_schema('trading_platform_new_account', $res);
    $dx_syn = $res->{trading_platform_new_account};

    $params = {
        trading_platform_accounts => 1,
        platform                  => 'dxtrade',
    };

    $t->await::authorize({authorize => $client1_token_read});
    my $list = $t->await::trading_platform_accounts($params);
    test_schema('trading_platform_accounts', $list);
    cmp_deeply($list->{trading_platform_accounts}, [$dx_acc, $dx_syn], 'responses match');

};

subtest 'passwords' => sub {

    my $params = {
        trading_platform_password_change => 1,
        old_password                     => 'Pr0tect!',
        new_password                     => 'Destr0y!',
    };

    $t->await::authorize({authorize => $client1_token_read});
    my $res = $t->await::trading_platform_password_change($params);
    is $res->{error}{code}, 'PermissionDenied', 'cannot change password with read scope';

    $t->await::authorize({authorize => $client1_token_admin});
    $res = $t->await::trading_platform_password_change($params);
    ok $res->{trading_platform_password_change}, 'successful response';
    test_schema('trading_platform_password_change', $res);

    my $code = BOM::Platform::Token->new({
            email       => $client1->email,
            expires_in  => 3600,
            created_for => 'trading_platform_password_reset',
        })->token;

    $params = {
        trading_platform_password_reset => 1,
        new_password                    => 'Rebui1ld!',
        verification_code               => $code,
    };

    $t->await::authorize({authorize => $client1_token_read});
    $res = $t->await::trading_platform_password_reset($params);
    is $res->{error}{code}, 'PermissionDenied', 'cannot change password with read scope';

    $t->await::authorize({authorize => $client1_token_admin});
    $res = $t->await::trading_platform_password_reset($params);
    ok $res->{trading_platform_password_reset}, 'successful response';
    test_schema('trading_platform_password_reset', $res);
};

subtest 'transfers' => sub {

    BOM::Test::Helper::Client::top_up($client1, 'USD', 10);

    my $params = {
        trading_platform_deposit => 1,
        platform                 => 'dxtrade',
        amount                   => 10,
        from_account             => $client1->loginid,
        to_account               => $dx_acc->{account_id},
    };

    $t->await::authorize({authorize => $client1_token_read});
    my $res = $t->await::trading_platform_deposit($params);
    is $res->{error}{code}, 'PermissionDenied', 'cannot deposit with read scope';

    $t->await::authorize({authorize => $client1_token_admin});
    $res = $t->await::trading_platform_deposit($params);
    is $res->{error}{code}, 'PermissionDenied', 'cannot deposit with admin scope';

    $t->await::authorize({authorize => $client1_token_payments});
    $res = $t->await::trading_platform_deposit($params);
    ok $res->{trading_platform_deposit}{transaction_id}, 'deposit response has transaction id';
    test_schema('trading_platform_deposit', $res);

    $params = {
        trading_platform_withdrawal => 1,
        platform                    => 'dxtrade',
        amount                      => 10,
        from_account                => $dx_acc->{account_id},
        to_account                  => $client1->loginid,
    };

    $t->await::authorize({authorize => $client1_token_read});
    $res = $t->await::trading_platform_withdrawal($params);
    is $res->{error}{code}, 'PermissionDenied', 'cannot withdraw with read scope';

    $t->await::authorize({authorize => $client1_token_admin});
    $res = $t->await::trading_platform_withdrawal($params);
    is $res->{error}{code}, 'PermissionDenied', 'cannot withdraw with admin scope';

    $t->await::authorize({authorize => $client1_token_payments});
    $res = $t->await::trading_platform_withdrawal($params);
    ok $res->{trading_platform_withdrawal}{transaction_id}, 'withdrawal response has transaction id';
    test_schema('trading_platform_withdrawal', $res);

    BOM::Test::Helper::Client::top_up($client2, 'USD', 20);

    $params = {
        trading_platform_deposit => 1,
        platform                 => 'dxtrade',
        amount                   => 10,
        from_account             => $client2->loginid,
        to_account               => $dx_acc->{account_id},
    };

    # client1 is authorized with payments scope
    $res = $t->await::trading_platform_deposit($params);
    is $res->{error}{code}, 'PlatformTransferOauthTokenRequired', 'cannot use sibling account with api token';

    $t->await::authorize({authorize => $client1_token_oauth});
    $res = $t->await::trading_platform_deposit($params);
    ok $res->{trading_platform_deposit}{transaction_id}, 'can use sibling account with oauth token';

    $res = $t->await::transfer_between_accounts({
        transfer_between_accounts => 1,
        accounts                  => 'all',
    });

    cmp_deeply(
        $res->{accounts},
        supersetof({
                account_type => 'dxtrade',
                balance      => num(10),
                loginid      => $dx_acc->{account_id},
                currency     => $dx_acc->{currency},
                market_type  => $dx_acc->{market_type},
                demo_account => 0
            },
            {
                account_type => 'dxtrade',
                balance      => num(0),
                loginid      => $dx_syn->{account_id},
                currency     => $dx_syn->{currency},
                market_type  => 'synthetic',
                demo_account => 0
            }
        ),
        'transfer_between_accounts with no params and accounts=all returns dx account'
    );

    # client1 is authorized with oauth token
    $res = $t->await::transfer_between_accounts({
        transfer_between_accounts => 1,
        account_from              => $dx_acc->{account_id},
        account_to                => $client2->loginid,
        amount                    => 10,
        currency                  => 'USD',
    });

    cmp_deeply(
        $res->{accounts},
        bag({
                account_type => 'dxtrade',
                balance      => num(0),
                loginid      => $dx_acc->{account_id},
                currency     => $dx_acc->{currency},
                market_type  => $dx_acc->{market_type},
            },
            {
                account_type => 'trading',
                balance      => num($client2->account->balance),
                currency     => $client2->currency,
                loginid      => $client2->loginid,
            }
        ),
        'successful withdrawal with transfer_between_accounts to sibling account using oauth token'
    );

    $t->await::authorize({authorize => $client2_token_payments});

    $res = $t->await::transfer_between_accounts({
        transfer_between_accounts => 1,
        account_from              => $client2->loginid,
        account_to                => $dx_acc->{account_id},
        amount                    => 10,
        currency                  => 'USD',
    });

    cmp_deeply(
        $res->{accounts},
        bag({
                account_type => 'dxtrade',
                balance      => num(10),
                loginid      => $dx_acc->{account_id},
                currency     => $dx_acc->{currency},
                market_type  => $dx_acc->{market_type},
            },
            {
                account_type => 'trading',
                balance      => num($client2->account->balance),
                currency     => $client2->currency,
                loginid      => $client2->loginid,
            }
        ),
        'successful deposit with transfer_between_accounts using api token'
    );

    $t->await::authorize({authorize => $client2_token_payments});

    $res = $t->await::transfer_between_accounts({
        transfer_between_accounts => 1,
        account_from              => $client2->loginid,
        account_to                => $dx_syn->{account_id},
        amount                    => 10,
        currency                  => 'USD',
    });

    cmp_deeply(
        $res->{accounts},
        bag({
                account_type => 'dxtrade',
                balance      => num(10),
                loginid      => $dx_syn->{account_id},
                currency     => $dx_syn->{currency},
                market_type  => 'synthetic',
            },
            {
                account_type => 'trading',
                balance      => num($client2->account->balance),
                currency     => $client2->currency,
                loginid      => $client2->loginid,
            }
        ),
        'successful deposit with transfer_between_accounts using api token'
    );
};

$t->finish_ok;

done_testing();
