use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::User::Password;
use BOM::User;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::Accounts;

BOM::Test::Helper::Token::cleanup_redis_tokens();

# init db
my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client->email($email);
$test_client->save;

my $test_loginid = $test_client->loginid;
my $user         = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->set_default_account('USD');
$test_client_vr->save;

my $email_mlt_mf    = 'mltmf@binary.com';
my $test_client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    residence   => 'at',
});
$test_client_mlt->email($email_mlt_mf);
$test_client_mlt->set_default_account('EUR');
$test_client_mlt->save;

my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    residence   => 'at',
});
$test_client_mf->email($email_mlt_mf);
$test_client_mf->save;

my $user_mlt_mf = BOM::User->create(
    email    => $email_mlt_mf,
    password => $hash_pwd
);
$user_mlt_mf->add_client($test_client_vr);
$user_mlt_mf->add_client($test_client_mlt);
$user_mlt_mf->add_client($test_client_mf);

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_loginid, 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_mlt      = $m->create_token($test_client_mlt->loginid, 'test token');

my $c = Test::BOM::RPC::QueueClient->new();

my $method = 'balance';
subtest 'balance' => sub {
    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');

    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
        )->{error}{message_to_client},
        'The token is invalid.',
        'invalid token error'
    );

    isnt(
        $c->tcall(
            $method,
            {
                token => $token,
            }
        )->{error}{message_to_client},
        'The token is invalid.',
        'no token error if token is valid'
    );

    is(
        $c->tcall(
            $method,
            {
                token => $token_disabled,
            }
        )->{error}{message_to_client},
        'This account is unavailable.',
        'check authorization'
    );

    is($c->tcall($method, {token => $token})->{balance},    '0.00', 'have 0 balance if no default account');
    is($c->tcall($method, {token => $token})->{currency},   '',     'have no currency if no default account');
    is($c->tcall($method, {token => $token})->{account_id}, '',     'have no account id if no default account');

    my $bal_email = 'balance@binary.com';
    my $bal_user  = BOM::User->create(
        email    => $bal_email,
        password => $hash_pwd,
    );

    my $bal_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $bal_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    my $bal_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $bal_mf_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });

    for my $c ($bal_mf, $bal_mlt, $bal_vr, $bal_mf_disabled) {
        $c->email($bal_email);
        $c->save;
        $bal_user->add_client($c);
    }

    $bal_mf->set_default_account('EUR');
    $bal_mf->save;

    $bal_mf->payment_free_gift(
        currency => 'EUR',
        amount   => 1000,
        remark   => 'free gift',
    );

    $bal_mlt->set_default_account('USD');
    $bal_mlt->save;
    $bal_mlt->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );

    $bal_vr->set_default_account('USD');
    $bal_vr->save;

    $bal_mf_disabled->set_default_account('USD');
    $bal_mf_disabled->save;
    $bal_mf_disabled->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    $bal_mf_disabled->status->set('disabled', 1, 'test disabled');

    my $bal_token = $m->create_token($bal_mlt->loginid, 'mlt token');

    my $expected_result = {
        'account_id' => $bal_mlt->default_account->id,
        'balance'    => '1000.00',
        'currency'   => 'USD',
        'loginid'    => $bal_mlt->loginid,
    };

    my $result = $c->tcall($method, {token => $bal_token});

    is_deeply($result, $expected_result, 'result is correct');
    my $args = {
        balance => 1,
        account => 'current'
    };

    for my $account ('current', $bal_mlt->loginid) {
        $args->{account} = $account;
        $result = $c->tcall(
            $method,
            {
                token => $bal_token,
                args  => $args
            });
        is_deeply($result, $expected_result, "account type '$account' ok",);
    }

    $args->{account} = 'all';
    my $t_mock = Test::MockModule->new('BOM::RPC::v3::Accounts');
    $t_mock->mock(
        'convert_currency',
        sub {
            my ($n, $from, $to) = @_;
            my $t = $from eq $to ? 1 : 1.5;
            return $n * $t;
        });
    $result = $c->tcall(
        $method,
        {
            token      => $bal_token,
            token_type => 'oauth_token',
            args       => $args,
        });
    is_deeply(
        $result,
        {
            'account_id' => $bal_mlt->default_account->id,
            'balance'    => '1000.00',
            'currency'   => 'USD',
            'loginid'    => $bal_mlt->loginid,
            'total'      => {
                'deriv' => {
                    'amount'   => '2500.00',
                    'currency' => 'USD'
                },
                'deriv_demo' => {
                    'amount'   => '0.00',
                    'currency' => 'USD'
                },
                'mt5' => {
                    'amount'   => '0.00',
                    'currency' => 'USD'
                },
                'mt5_demo' => {
                    'amount'   => '0.00',
                    'currency' => 'USD'
                },
            },
            accounts => {
                $bal_mf->loginid => {
                    'currency_rate_in_total_currency' => 1.5,
                    'account_id'                      => $bal_mf->default_account->id,
                    'balance'                         => '1000.00',
                    'currency'                        => 'EUR',
                    'type'                            => 'deriv',
                    'demo_account'                    => 0,
                    'converted_amount'                => '1500.00',
                    'status'                          => 1,
                },
                $bal_mlt->loginid => {
                    'currency_rate_in_total_currency' => 1,
                    'account_id'                      => $bal_mlt->default_account->id,
                    'balance'                         => '1000.00',
                    'currency'                        => 'USD',
                    'type'                            => 'deriv',
                    'demo_account'                    => 0,
                    'converted_amount'                => '1000.00',
                    'status'                          => 1,
                },
                $bal_vr->loginid => {
                    'currency_rate_in_total_currency' => 1,
                    'account_id'                      => $bal_vr->default_account->id,
                    'balance'                         => '0.00',
                    'currency'                        => 'USD',
                    'type'                            => 'deriv',
                    'demo_account'                    => 1,
                    'converted_amount'                => '0.00',
                    'status'                          => 1,
                }}
        },
        'result is correct for mix of real, virtual and disabled clients'
    );

    $result = $c->tcall(
        $method,
        {
            token      => $token_mlt,
            token_type => 'oauth_token',
            args       => $args,
        });

    $expected_result = {
        'account_id' => $test_client_mlt->default_account->id,
        'balance'    => '0.00',
        'currency'   => 'EUR',
        'loginid'    => $test_client_mlt->loginid,
        'total'      => {
            'deriv' => {
                'amount'   => '0.00',
                'currency' => 'EUR'
            },
            'deriv_demo' => {
                'amount'   => '0.00',
                'currency' => 'EUR'
            },
            'mt5' => {
                'amount'   => '0.00',
                'currency' => 'EUR'
            },
            'mt5_demo' => {
                'amount'   => '0.00',
                'currency' => 'EUR'
            },
        },
        accounts => {
            $test_client_mlt->loginid => {
                'currency_rate_in_total_currency' => 1,
                'account_id'                      => $test_client_mlt->default_account->id,
                'balance'                         => '0.00',
                'currency'                        => 'EUR',
                'type'                            => 'deriv',
                'demo_account'                    => 0,
                'converted_amount'                => '0.00',
                'status'                          => 1,
            },
            $test_client_vr->loginid => {
                'currency_rate_in_total_currency' => 1.5,
                'account_id'                      => $test_client_vr->default_account->id,
                'balance'                         => '0.00',
                'currency'                        => 'USD',
                'type'                            => 'deriv',
                'demo_account'                    => 1,
                'converted_amount'                => '0.00',
                'status'                          => 1,
            },
            $test_client_mf->loginid => {
                'account_id'       => '',
                'balance'          => '0.00',
                'currency'         => '',
                'type'             => 'deriv',
                'demo_account'     => 0,
                'converted_amount' => '0.00',
                'status'           => 0,
            }}};

    is_deeply($result, $expected_result, 'mt5 result is ok');

    my $balence_currency_email = 'balance_currency@binary.com';
    my $bal_currency_user      = BOM::User->create(
        email    => $balence_currency_email,
        password => $hash_pwd,
    );

    my $client_cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $client_cr_ust = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    for my $c ($client_cr_btc, $client_cr_ust) {
        $c->email($balence_currency_email);
        $c->save;
        $bal_currency_user->add_client($c);
    }

    $client_cr_btc->set_default_account('BTC');
    $client_cr_btc->save;

    $client_cr_ust->set_default_account('UST');
    $client_cr_ust->save;

    my $cr_btc_token = $m->create_token($client_cr_btc->loginid, 'cr_btc token');

    $result = $c->tcall(
        $method,
        {
            token      => $cr_btc_token,
            token_type => 'oauth_token',
            args       => $args
        });

    is $result->{total}{deriv}{currency}, 'USD', 'USD currency used for total balance when no fiat accounts exist';

    my $client_cr_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client_cr_eur->email($balence_currency_email);
    $client_cr_eur->set_default_account('EUR');
    $client_cr_eur->save;
    $bal_currency_user->add_client($client_cr_eur);

    $result = $c->tcall(
        $method,
        {
            token      => $cr_btc_token,
            token_type => 'oauth_token',
            args       => $args
        });

    is $result->{total}{deriv}{currency}, 'EUR', 'fiat account currency used for total balance';

    $result = $c->tcall(
        $method,
        {
            token => $cr_btc_token,
            args  => $args,
        });
    is $result->{error}{code}, 'PermissionDenied', 'need oauth token for balance all';

};

done_testing();
