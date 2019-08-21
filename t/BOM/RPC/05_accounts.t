use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use Encode;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use Encode qw(encode);
use Email::Address::UseXS;
use Digest::SHA qw(hmac_sha256_hex);

use Format::Util::Numbers qw/formatnumber/;
use Scalar::Util qw/looks_like_number/;
use LandingCompany::Registry;
use BOM::Test::Email;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Platform::Token::API;
use BOM::RPC::v3::Utility;
use BOM::User::Password;
use BOM::User;
use BOM::User::Client;
use BOM::Config;
use BOM::MT5::User::Async;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

package MojoX::JSON::RPC::Client;
use Test::More;    # import ok again into this namespace
use Data::Dumper;

sub tcall {
    my $self   = shift;
    my $method = shift;
    my $params = shift;
    my $r      = $self->call_response($method, $params);
    ok($r->result,    'rpc response ok');
    ok(!$r->is_error, 'rpc response ok');
    if ($r->is_error) {
        diag(Dumper($r));
    }
    return $r->result;
}

sub call_response {
    my $self   = shift;
    my $method = shift;
    my $params = shift;
    my $r      = $self->call(
        "/$method",
        {
            id     => Data::UUID->new()->create_str(),
            method => $method,
            params => $params
        });
    return $r;
}

package main;

# init db
my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client->email($email);
$test_client->save;

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;

my $test_loginid = $test_client->loginid;
my $user         = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

my $test_client_cr_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});

$test_client_cr_vr->email('sample@binary.com');
$test_client_cr_vr->save;

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    citizen     => 'at',
});
$test_client_cr->email('sample@binary.com');
$test_client_cr->set_default_account('USD');
$test_client_cr->save;

my $test_client_cr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_cr_2->email('sample@binary.com');
$test_client_cr_2->save;

my $user_cr = BOM::User->create(
    email    => 'sample@binary.com',
    password => $hash_pwd
);

$user_cr->add_client($test_client_cr_vr);
$user_cr->add_client($test_client_cr);
$user_cr->add_client($test_client_cr_2);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $test_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
    citizen     => ''
});
$test_client_mx->email($email);

my $test_client_vr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr_2->email($email);
$test_client_vr_2->save;

my $email_mlt_mf    = 'mltmf@binary.com';
my $test_client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    residence   => 'at',
});
$test_client_mlt->email($email_mlt_mf);
$test_client_mlt->set_default_account('EUR');
$test_client_mlt->save;

my $test_client_mlt_loginid = $test_client_mlt->loginid;

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
$user_mlt_mf->add_client($test_client_vr_2);
$user_mlt_mf->add_client($test_client_mlt);
$user_mlt_mf->add_client($test_client_mf);

my $m              = BOM::Platform::Token::API->new;
my $token1         = $m->create_token($test_loginid, 'test token');
my $token_21       = $m->create_token($test_client_cr->loginid, 'test token');
my $token_cr_2     = $m->create_token($test_client_cr_2->loginid, 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_vr       = $m->create_token($test_client_vr->loginid, 'test token');
my $token_with_txn = $m->create_token($test_client2->loginid, 'test token');
my $token_mx       = $m->create_token($test_client_mx->loginid, 'test token');
my $token_mlt      = $m->create_token($test_client_mlt->loginid, 'test token');
my $token_mf       = $m->create_token($test_client_mf->loginid, 'test token');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw(JPY USD JPY-USD);

my $now        = Date::Utility->new('2005-09-21 06:46:00');
my $underlying = create_underlying('R_50');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => $now,
    });

$test_client2->payment_free_gift(
    currency => 'USD',
    amount   => 1000,
    remark   => 'free gift',
);

my $old_tick1 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 99,
    underlying => 'R_50',
    quote      => 76.5996,
    bid        => 76.6010,
    ask        => 76.2030,
});

my $old_tick2 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 52,
    underlying => 'R_50',
    quote      => 76.6996,
    bid        => 76.7010,
    ask        => 76.3030,
});

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

my $R_100_start = Date::Utility->new('1413892500');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $R_100_start,
    });

my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $R_100_start->epoch,
    quote      => 100
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $R_100_start->epoch + 30,
    quote      => 111
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $R_100_start->epoch + 14400,
    quote      => 80
});

# test begin
my $t      = Test::Mojo->new('BOM::RPC::Transport::HTTP');
my $c      = MojoX::JSON::RPC::Client->new(ua => $t->app->ua);
my $method = 'payout_currencies';
subtest $method => sub {
    # we shouldn't care about order of currencies
    # we just need to send array back
    cmp_bag($c->tcall($method, {token => '12345'}), [LandingCompany::Registry->new()->all_currencies()], 'invalid token will get all currencies');
    cmp_bag(
        $c->tcall(
            $method,
            {
                token => undef,
            }
        ),
        [LandingCompany::Registry->new()->all_currencies()],
        'undefined token will get all currencies'
    );

    cmp_bag($c->tcall($method, {token => $token_21}), ['USD'], "will return client's currency");
    cmp_bag($c->tcall($method, {}), [LandingCompany::Registry->new()->all_currencies()], "will return legal currencies if no token");
};

$method = 'landing_company';
subtest $method => sub {
    is_deeply(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                args     => {landing_company => 'nosuchcountry'}}
        ),
        {
            error => {
                message_to_client => '未知着陆公司。',
                code              => 'UnknownLandingCompany'
            }
        },
        "no such landing company"
    );
    my $ag_lc = $c->tcall($method, {args => {landing_company => 'ag'}});
    ok($ag_lc->{gaming_company},    "ag have gaming company");
    ok($ag_lc->{financial_company}, "ag have financial company");
    ok(!$c->tcall($method, {args => {landing_company => 'de'}})->{gaming_company},    "de have no gaming_company");
    ok(!$c->tcall($method, {args => {landing_company => 'hk'}})->{financial_company}, "hk have no financial_company");
};

$method = 'landing_company_details';
subtest $method => sub {
    is_deeply(
        $c->tcall($method, {args => {landing_company_details => 'nosuchlandingcompany'}}),
        {
            error => {
                message_to_client => 'Unknown landing company.',
                code              => 'UnknownLandingCompany'
            }
        },
        "no such landing company"
    );
    my $result = $c->tcall($method, {args => {landing_company_details => 'svg'}});
    is($result->{name}, 'Binary (SVG) Ltd.', "details result ok");
    cmp_bag([keys %{$result->{currency_config}->{volidx}}], [LandingCompany::Registry->new()->all_currencies()], "currency config ok");
    ok(!(grep { !looks_like_number($_) } get_values($result->{currency_config})), 'limits for svg are all numeric');

    $result = $c->tcall($method, {args => {landing_company_details => 'maltainvest'}});
    cmp_bag([keys %{$result->{currency_config}->{forex}}], ['USD', 'EUR', 'GBP'], "currency config for maltainvest ok");
    ok(!(grep { !looks_like_number($_) } get_values($result->{currency_config})), 'limits for maltainvest are all numeric');
};

$method = 'statement';
subtest $method => sub {
    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
            )->{error}{message_to_client},
        'The token is invalid.',
        'invalid token error if token undef'
    );
    isnt(
        $c->tcall(
            $method,
            {
                token => $token1,
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
    is($c->tcall($method, {token => $token1})->{count}, 0, 'have 0 statements if no default account');

    my $contract_expired = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        stake        => 100,
        date_start   => $now->epoch - 100,
        date_expiry  => $now->epoch - 50,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        barrier      => 'S0P',
    };

    my $txn = BOM::Transaction->new({
        client              => $test_client2,
        contract_parameters => $contract_expired,
        price               => 100,
        amount_type         => 'stake',
        purchase_date       => $now->epoch - 101,
    });

    $txn->buy(skip_validation => 1);
    my $result = $c->tcall($method, {token => $token_with_txn});
    is($result->{transactions}[0]{action_type}, 'sell', 'the transaction is sold, so _sell_expired_contracts is called');
    is($result->{count},                        3,      "have 3 statements");
    $result = $c->tcall(
        $method,
        {
            token => $token_with_txn,
            args  => {description => 1}});

    is(
        $result->{transactions}[0]{longcode},
        'Win payout if Volatility 50 Index is strictly higher than entry spot at 50 seconds after contract start time.',
        "if have short code, we get more details"
    );
    is($result->{transactions}[2]{longcode}, 'free gift', "if no short code, then longcode is the remark");

    # here the expired contract is sold, so we can get the txns as test value
    my $txns = BOM::Database::DataMapper::Transaction->new({db => $test_client2->default_account->db})
        ->get_transactions_ws({}, $test_client2->default_account);
    $result = $c->tcall($method, {token => $token_with_txn});
    is($result->{transactions}[0]{transaction_time}, Date::Utility->new($txns->[0]{sell_time})->epoch,     'transaction time correct for sell');
    is($result->{transactions}[1]{transaction_time}, Date::Utility->new($txns->[1]{purchase_time})->epoch, 'transaction time correct for buy ');
    is($result->{transactions}[2]{transaction_time}, Date::Utility->new($txns->[2]{payment_time})->epoch,  'transaction time correct for payment');
    {
        my $sell_tr = [grep { $_->{action_type} && $_->{action_type} eq 'sell' } @{$result->{transactions}}]->[0];
        my $buy_tr  = [grep { $_->{action_type} && $_->{action_type} eq 'buy' } @{$result->{transactions}}]->[0];
        is($sell_tr->{reference_id}, $buy_tr->{transaction_id}, 'transaction id is same for buy and sell ');
    }

    $contract_expired = {
        underlying   => create_underlying('R_100'),
        bet_type     => 'CALL',
        currency     => 'USD',
        stake        => 100,
        date_start   => $R_100_start->epoch,
        date_pricing => $R_100_start->epoch,
        date_expiry  => 1413906900,
        current_tick => $entry_tick,
        entry_tick   => $entry_tick,
        barrier      => 'S0P',
    };

    $txn = BOM::Transaction->new({
            client              => $test_client2,
            contract_parameters => $contract_expired,
            price               => 100,
            payout              => 200,
            amount_type         => 'stake',
            purchase_date       => $R_100_start->epoch - 101,

    });
    $txn->buy(skip_validation => 1);
    $result = $c->tcall($method, {token => $token_with_txn});
    is($result->{transactions}[0]{action_type}, 'sell', 'the transaction is sold, so _sell_expired_contracts is called');
    is($result->{count},                        5,      "have 5 statements");
    $result = $c->tcall(
        $method,
        {
            token => $token_with_txn,
            args  => {description => 1}});
    is(
        $result->{transactions}[0]{longcode},
        'Win payout if Volatility 100 Index is strictly higher than entry spot at 4 hours after contract start time.',
        "if have short code, then we get more details"
    );

    # here the expired contract is sold, so we can get the txns as test value
    $txns = BOM::Database::DataMapper::Transaction->new({db => $test_client2->default_account->db})
        ->get_transactions_ws({}, $test_client2->default_account);
    $result = $c->tcall($method, {token => $token_with_txn});
    cmp_ok(abs($result->{transactions}[0]{transaction_time} - Date::Utility->new($txns->[0]{sell_time})->epoch),
        '<=', 2, 'transaction time correct for sell');
    cmp_ok(abs($result->{transactions}[1]{transaction_time} - Date::Utility->new($txns->[1]{purchase_time})->epoch),
        '<=', 2, 'transaction time correct for buy ');
    cmp_ok(abs($result->{transactions}[2]{transaction_time} - Date::Utility->new($txns->[2]{payment_time})->epoch),
        '<=', 2, 'transaction time correct for payment');
    {
        my $sell_tr = [grep { $_->{action_type} && $_->{action_type} eq 'sell' } @{$result->{transactions}}]->[0];
        my $buy_tr  = [grep { $_->{action_type} && $_->{action_type} eq 'buy' } @{$result->{transactions}}]->[0];
        is($sell_tr->{reference_id}, $buy_tr->{transaction_id}, 'transaction id is same for buy and sell ');
    }

};

# request report
$method = 'request_report';
subtest $method => sub {

    subtest 'email_statement' => sub {
        my $result = $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {
                    request_report => 1,
                    report_type    => "statement",
                    date_from      => 1534036304,
                    date_to        => 1538036304,
                }});
        is $result->{report_status}, 1, 'email statement task has been emitted successfully.';

        $result = $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {
                    request_report => 1,
                    report_type    => "statement",
                    date_from      => 1413950000,
                    date_to        => 1413906900,
                }});
        is $result->{error}->{message_to_client}, 'From date must be before To date for sending statement', 'from date must be before to date';
    };

};

$method = 'account_statistics';
subtest $method => sub {

    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
            )->{error}{message_to_client},
        'The token is invalid.',
        'invalid token error if token undef'
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

    my $res = $c->tcall($method, {token => $token_with_txn});
    ok($res->{total_deposits} eq '1000.00', 'test_client2 has deposit of 1000.00');
    ok($res->{total_withdrawals} eq '0.00', 'test_client2 has withdrawals of 0.00');
    ok($res->{currency} eq 'USD',           'currency is USD');

    $test_client2->payment_free_gift(
        currency => 'USD',
        amount   => -200,
        remark   => 'not so free gift',
    );

    $test_client2->payment_free_gift(
        currency => 'USD',
        amount   => 2000,
        remark   => 'free gift',
    );

    $res = $c->tcall($method, {token => $token_with_txn});
    ok($res->{total_deposits} eq '3000.00',   'total_deposits is 3000.00');
    ok($res->{total_withdrawals} eq '200.00', 'total_withdrawals is 200.00');
    ok($res->{currency} eq 'USD',             'currency is USD');

    $test_client2->payment_free_gift(
        currency => 'USD',
        amount   => -1800,
        remark   => 'not so free gift',
    );

    $res = $c->tcall($method, {token => $token_with_txn});
    ok($res->{total_deposits} eq '3000.00',    'total_deposits is 3000.00');
    ok($res->{total_withdrawals} eq '2000.00', 'total_withdrawals is 2000.00');
    ok($res->{currency} eq 'USD',              'currency is USD');

    # token_cr_2 client does not have a default account, so the currency contain nothing
    $res = $c->tcall($method, {token => $token_cr_2});
    ok($res->{total_deposits} eq '0.00',    'total_deposits is 0.00');
    ok($res->{total_withdrawals} eq '0.00', 'total_withdrawals is 0.00');
    ok($res->{currency} eq '',              'currency is undef');

};

# profit_table
$method = 'profit_table';
subtest $method => sub {
    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
            )->{error}{message_to_client},
        'The token is invalid.',
        'invalid token error if token undef'
    );
    isnt(
        $c->tcall(
            $method,
            {
                token => $token1,
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

    #create a new transaction for test
    my $contract_expired = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        stake        => 100,
        date_start   => $now->epoch - 100,
        date_expiry  => $now->epoch - 50,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        barrier      => 'S0P',
    };

    my $txn = BOM::Transaction->new({
        client              => $test_client2,
        contract_parameters => $contract_expired,
        price               => 100,
        amount_type         => 'stake',
        purchase_date       => $now->epoch - 101,
    });

    $txn->buy(skip_validation => 1);

    my $result = $c->tcall($method, {token => $token_with_txn});
    is($result->{count}, 3, 'the new transaction is sold so _sell_expired_contracts is called');

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $test_client2->loginid,
            currency_code  => $test_client2->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $test_client2->loginid,
                    operation      => 'replica',
                }
            )->db,
        });
    my $args    = {};
    my $data    = $fmb_dm->get_sold_bets_of_account($args);
    my $expect0 = {
        'sell_price'     => '100.00',
        'contract_id'    => $txn->contract_id,
        'transaction_id' => $txn->transaction_id,
        'sell_time'      => Date::Utility->new($data->[1]{sell_time})->epoch,
        'buy_price'      => '100.00',
        'purchase_time'  => Date::Utility->new($data->[1]{purchase_time})->epoch,
        'payout'         => formatnumber('price', $test_client2->currency, $txn->contract->payout),
        'app_id'         => undef
    };
    is_deeply($result->{transactions}[1], $expect0, 'result is correct');
    $expect0->{longcode}  = 'Win payout if Volatility 50 Index is strictly higher than entry spot at 50 seconds after contract start time.';
    $expect0->{shortcode} = $data->[1]{short_code};
    $result               = $c->tcall(
        $method,
        {
            token => $token_with_txn,
            args  => {description => 1}});

    is_deeply($result->{transactions}[1], $expect0, 'the result with description ok');
    is(
        $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {after => '2006-01-01 01:01:01'}}
            )->{count},
        1,
        'result is correct for arg after'
    );
    is(
        $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {before => '2004-01-01 01:01:01'}}
            )->{count},
        0,
        'result is correct for arg after'
    );
};

$method = 'balance';
subtest $method => sub {
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
                token => $token1,
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

    is($c->tcall($method, {token => $token1})->{balance},  '0.00', 'have 0 balance if no default account');
    is($c->tcall($method, {token => $token1})->{currency}, '',     'have no currency if no default account');
    my $result = $c->tcall($method, {token => $token_21});
    is_deeply(
        $result,
        {
            'currency' => 'USD',
            'balance'  => '0.00',
            'loginid'  => $test_client_cr->loginid
        },
        'result is correct'
    );
};

# placing this test here as need to test the calling of financial_assessment
# before a financial assessment record has been created
$method = 'get_financial_assessment';
subtest $method => sub {
    my $args = {"get_financial_assessment" => 1};
    my $res = $c->tcall(
        $method,
        {
            token => $token_vr,
            args  => $args
        });
    is($res->{error}->{code}, 'PermissionDenied', "Not allowed for virtual account");

    $res = $c->tcall(
        $method,
        {
            args  => $args,
            token => $token1
        });
    is_deeply($res, {}, 'empty assessment details');
};

$method = 'get_account_status';
subtest $method => sub {
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
                token => $token1,
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

    # test 'financial_assessment_not_complete'
    my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();

    # function to repeatedly test financial assessment
    sub test_financial_assessment {
        my ($data, $is_present, $msg) = @_;
        $test_client->financial_assessment({
            data => encode_json_utf8($data),
        });
        $test_client->save();
        my $res = ((grep { $_ eq 'financial_assessment_not_complete' } @{$c->tcall($method, {token => $token1})->{status}}) == $is_present);

        ok($res, $msg);
    }

    # 'financial_assessment_not_complete' should not present when everything is complete
    test_financial_assessment($data, 0, 'financial_assessment_not_complete should not be present when questions are answered properly');

    # When some questions are not answered
    delete $data->{account_turnover};
    test_financial_assessment($data, 1, 'financial_assessment_not_complete should present when questions are not answered');

    # When some answers are empty
    $data->{account_turnover} = "";
    test_financial_assessment($data, 1, 'financial_assessment_not_complete should be present when some answers are empty');

    # When the client's risk classification is different
    $test_client->aml_risk_classification('high');
    $test_client->save();
    test_financial_assessment($data, 1, "financial_assessment_not_complete should present regardless of the client's risk classification");
    # duplicate_account is not supposed to be shown to the users
    $test_client->status->set('duplicate_account');
    cmp_deeply(
        $c->tcall($method, {token => $token_21}),
        {
            status                        => noneof(qw(duplicate_account)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
        },
        'duplicate_account is not in the status'
    );

    $test_client->status->clear_duplicate_account;

    # $test_client->status->set('tnc_approval', 'test staff', 1);

    # reset the risk classification for the following test
    $test_client->aml_risk_classification('low');
    $test_client->save();

    $test_client_cr->set_authentication('ID_DOCUMENT')->status('needs_action');
    $test_client_cr->save;
    cmp_deeply(
        $c->tcall($method, {token => $token_21}),
        {
            status                        => superbagof(qw(document_needs_action)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '1',
        },
        'authentication page should be shown if needs action is set regardless of balance'
    );

    $test_client_cr->set_authentication('ID_DOCUMENT')->status('under_review');
    $test_client_cr->save;
    cmp_deeply(
        $c->tcall($method, {token => $token_21}),
        {
            status                        => superbagof(qw(document_under_review)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '1',
        },
        'authentication page should be shown if under review is set regardless of balance'
    );

    # Revert under review state
    $test_client_cr->get_authentication('ID_DOCUMENT')->delete;
    $test_client_cr->save;

    cmp_deeply(
        $c->tcall($method, {token => $token_21}),
        {
            status                        => noneof(qw(document_needs_action document_under_review)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
        },
        'authentication should not be shown if neither needs action nor under review is set if balance is < 4k'
    );

    cmp_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status                        => noneof(qw(authenticated)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '1',
        },
        'prompt for non authenticated MF client'
    );

    $test_client->set_authentication('ID_DOCUMENT')->status('pass');
    $test_client->status->set("professional");
    $test_client->save;

    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock('has_deposits', sub { return 0 });

    cmp_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status                        => superbagof(qw(authenticated)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
        },
        'authenticated, no deposits so it will not prompt for authentication'
    );

    # Authenticated clients are automatically age_verified. This following test exists for legacy clients.
    $mocked_client->mock('has_deposits', sub { return 1 });
    my $mocked_status = Test::MockModule->new(ref($test_client->status));
    $mocked_status->mock('age_verification', sub { return 0 });

    cmp_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status                        => superbagof(qw(authenticated)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '1',
        },
        'authenticated, has deposits but no age verified status so validation triggered and generated an exception so it will ask to authenticate'
    );

    $mocked_status->unmock('age_verification');

    $test_client->status->set('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID');

    cmp_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status                        => superbagof(qw(age_verification authenticated)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
        },
        'authenticated, has deposits and age verified so no need to prompt '
    );
    $mocked_client->unmock('has_deposits');

    $test_client->status->clear_professional;
    $test_client->save;

    $mocked_client->mock('documents_expired', sub { return 1 });
    cmp_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status                        => superbagof(qw(document_expired)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
        },
        'correct account status returned for document expired'
    );

    $mocked_client->mock(
        'documents_expired',
        sub {
            my ($self, $date) = @_;
            return 0 unless $date;
            my $date_obj = Date::Utility->new($date);
            return 1
                if $date_obj->is_after(Date::Utility->today)
                and $date_obj->is_before(Date::Utility->today->plus_time_interval('1mo')->plus_time_interval('1d'));
        });
    cmp_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status                        => superbagof(qw(document_expiring_soon)),
            risk_classification           => 'low',
            prompt_client_to_authenticate => '0',
        },
        'correct account status returned for document expiring in next month'
    );

    $mocked_client->unmock('documents_expired');

};

$method = 'change_password';
subtest $method => sub {
    my $oldpass = '1*VPB0k.BCrtHeWoH8*fdLuwvoqyqmjtDF2FfrUNO7A0MdyzKkelKhrc7MQjNQ=';
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'new_password',
                user_pass    => '1*VPB0k.BCrtHeWoH8*fdLuwvoqyqmjtDF2FfrUNO7A0MdyzKkelKhrc7MQjPQ='
            }
            )->{error}->{message_to_client},
        'Old password is wrong.',
        'Old password is wrong.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'old_password',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'New password is same as old password.',
        'New password is same as old password.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'water',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'New#_p$ssword',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'no number.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'pa$5A',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'to short.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'pass$5ss',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'no upper case.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'PASS$5SS',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'no lower case.',
    );
    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
            )->{error}{message_to_client},
        'The token is invalid.',
        'invlaid token error'
    );
    isnt(
        $c->tcall(
            $method,
            {
                token => $token1,
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

    is($c->tcall($method, {})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => $token_disabled,
            }
            )->{error}{message_to_client},
        'This account is unavailable.',
        'need a valid client'
    );
    my $params = {
        token => $token1,
    };
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', 'need token_type');
    $params->{token_type} = 'hello';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', 'need token_type');
    $params->{token_type}         = 'oauth_token';
    $params->{args}{old_password} = 'old_password';
    $params->{cs_email}           = 'cs@binary.com';
    $params->{client_ip}          = '127.0.0.1';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Old password is wrong.');
    $params->{args}{old_password} = $password;
    $params->{args}{new_password} = $password;
    is($c->tcall($method, $params)->{error}{message_to_client}, 'New password is same as old password.');
    $params->{args}{new_password} = '111111111';
    is($c->tcall($method, $params)->{error}{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.');
    my $new_password = 'Fsfjxljfwkls3@fs9';
    $params->{args}{new_password} = $new_password;
    mailbox_clear();
    is($c->tcall($method, $params)->{status}, 1, 'update password correctly');
    my $subject = 'Your password has been changed.';
    my $msg     = mailbox_search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");
    $user = BOM::User->new(id => $user->{id});
    isnt($user->{password}, $hash_pwd, 'user password updated');
    $test_client->load;
    isnt($user->{password}, $hash_pwd, 'client password updated');
    $password = $new_password;
};

$method = 'cashier_password';
subtest $method => sub {

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
                token => $token1,
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
    is($c->tcall($method, {token => $token_vr})->{error}{message_to_client}, 'Permission denied.', 'need real money account');
    my $params = {
        token => $token1,
        args  => {}};
    is($c->tcall($method, $params)->{status}, 0, 'no unlock_password && lock_password, and not set password before, status will be 0');
    my $tmp_password     = 'sfjksfSFjsk78Sjlk';
    my $tmp_new_password = 'bjxljkwFWf278xK';
    $test_client->cashier_setting_password($tmp_password);
    $test_client->save;
    is($c->tcall($method, $params)->{status}, 1, 'no unlock_password && lock_password, and set password before, status will be 1');
    $params->{args}{lock_password} = $tmp_new_password;
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Your cashier was locked.', 'return error if already locked');
    $test_client->cashier_setting_password('');
    $test_client->save;
    $params->{args}{lock_password} = $password;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Please use a different password than your login password.',
        'return error if lock password same with user password'
    );
    $params->{args}{lock_password} = '1111111';
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'check strong'
    );
    $params->{args}{lock_password} = $tmp_new_password;

    mailbox_clear();
    # here I mocked function 'save' to simulate the db failure.
    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock('save', sub { return undef });
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your request.',
        'return error if cannot save password'
    );
    $mocked_client->unmock_all;

    is($c->tcall($method, $params)->{status}, 1, 'set password success');
    my $subject = 'Cashier password updated';
    my $msg     = mailbox_search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");

    # test unlock
    $test_client->cashier_setting_password('');
    $test_client->save;
    delete $params->{args}{lock_password};
    $params->{args}{unlock_password} = '123456';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Your cashier was not locked.', 'return error if not locked');

    mailbox_clear();
    $test_client->cashier_setting_password(BOM::User::Password::hashpw($tmp_password));
    $test_client->save;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, you have entered an incorrect cashier password',
        'return error if not correct'
    );
    $subject = 'Failed attempt to unlock cashier section';
    $msg     = mailbox_search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");

    # here I mocked function 'save' to simulate the db failure.
    $mocked_client->mock('save', sub { return undef });
    $params->{args}{unlock_password} = $tmp_password;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your request.',
        'return error if cannot save'
    );
    $mocked_client->unmock_all;

    mailbox_clear();
    is($c->tcall($method, $params)->{status}, 0, 'unlock password ok');
    $test_client->load;
    ok(!$test_client->cashier_setting_password, 'Cashier password unset');
    $subject = 'Cashier password updated';
    $msg     = mailbox_search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");
};

$method = 'get_settings';
subtest $method => sub {
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
                token => $token1,
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

    my $params = {
        token => $token_21,
    };

    my $result = $c->tcall($method, $params);
    note explain $result;
    is_deeply(
        $result,
        {
            'country'                        => 'Indonesia',
            'residence'                      => 'Indonesia',
            'salutation'                     => 'MR',
            'is_authenticated_payment_agent' => '0',
            'country_code'                   => 'id',
            'date_of_birth'                  => '267408000',
            'address_state'                  => 'LA',
            'address_postcode'               => '232323',
            'phone'                          => '+112123121',
            'last_name'                      => 'pItT',
            'email'                          => 'sample@binary.com',
            'address_line_2'                 => '301',
            'address_city'                   => 'Beverly Hills',
            'address_line_1'                 => 'Civic Center',
            'first_name'                     => 'bRaD',
            'email_consent'                  => '0',
            'allow_copiers'                  => '0',
            'client_tnc_status'              => '',
            'place_of_birth'                 => undef,
            'tax_residence'                  => undef,
            'tax_identification_number'      => undef,
            'account_opening_reason'         => undef,
            'request_professional_status'    => 0,
            'citizen'                        => 'at',
            'user_hash'                      => hmac_sha256_hex($user_cr->email, BOM::Config::third_party()->{elevio}->{account_secret}),
            'has_secret_answer'              => 1,
        });

    $params->{token} = $token1;
    $test_client->status->set('tnc_approval', 'system', 1);
    is($c->tcall($method, $params)->{client_tnc_status}, 1, 'tnc status set');
    $params->{token} = $token_vr;
    is_deeply(
        $c->tcall($method, $params),
        {
            'email'             => 'abc@binary.com',
            'country'           => 'Indonesia',
            'residence'         => 'Indonesia',
            'country_code'      => 'id',
            'email_consent'     => '0',
            'has_secret_answer' => '1',
            'user_hash'         => hmac_sha256_hex($user->email, BOM::Config::third_party()->{elevio}->{account_secret}),
        },
        'vr client return less messages'
    );
};

$method = 'account_closure';
subtest $method => sub {
    my $args = {
        "account_closure" => 1,
        "reason"          => 'Financial concerns'
    };

    my $email = 'def456@email.com';

    # Create user
    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    my $new_client_handler = sub {
        my ($broker_code, $currency) = @_;
        $currency //= 'USD';

        my $new_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => $broker_code});

        $new_client->set_default_account($currency);
        $new_client->email($email);
        $new_client->save;
        $user->add_client($new_client);

        return $new_client;
    };

    my $payment_handler = sub {
        my ($client, $amount) = @_;

        $client->payment_legacy_payment(
            currency     => $client->currency,
            amount       => $amount,
            remark       => 'testing',
            payment_type => 'ewallet'
        );

        return 1;
    };

    # Create VR client
    my $test_client_vr = $new_client_handler->('VRTC');

    # Create CR client (first)
    my $test_client = $new_client_handler->('CR');

    # Tokens
    my $token = $m->create_token($test_client->loginid, 'test token');

    my $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    # Test with single real account (no balance)
    # Test with virtual account
    is($res->{status}, 1, 'Successfully received request');
    ok($test_client_vr->status->disabled, 'Virtual account disabled');
    ok($test_client->status->disabled,    'CR account disabled');

    $test_client_vr->status->clear_disabled;
    $test_client->status->clear_disabled;

    ok(!$test_client->status->disabled, 'CR account is enabled back again');

    subtest "Open Contracts" => sub {
        my $mock = Test::MockModule->new('BOM::User::Client');
        $mock->mock(
            get_open_contracts => sub {
                return [1];
            });

        $res = $c->tcall(
            $method,
            {
                token => $token,
                args  => $args
            });

        is($res->{error}->{code}, 'AccountHasOpenPositions', 'Correct error code');
        my $loginid = $test_client->loginid;
        is(
            $res->{error}->{message_to_client},
            "Please ensure all positions in your account(s) are closed before proceeding: $loginid.",
            "Correct error message"
        );
        is_deeply($res->{error}->{details}, {accounts => {$loginid => 1}}, "Correct error details");
        ok(!$test_client->status->disabled,    'CR account is not disabled');
        ok(!$test_client_vr->status->disabled, 'Virtual account is also not disabled');

        $mock->unmock_all;
        $test_client_vr->status->clear_disabled;
        $test_client->status->clear_disabled;
    };

    $payment_handler->($test_client, 1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    # Test with single real account (balance)
    is($res->{error}->{code}, 'ExistingAccountHasBalance', 'Correct error code');
    ok(!$test_client->status->disabled,    'CR account is not disabled');
    ok(!$test_client_vr->status->disabled, 'Virtual account is also not disabled');

    my $test_client_2 = $new_client_handler->('CR', 'BTC');
    $payment_handler->($test_client,   -1);
    $payment_handler->($test_client_2, 1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    # Test with real siblings account (balance)
    my $loginid = $test_client_2->loginid;
    is($res->{error}->{code}, 'ExistingAccountHasBalance', 'Correct error code');
    is(
        $res->{error}->{message_to_client},
        "Please withdraw all funds from your account(s) before proceeding: $loginid.",
        'Correct error message for sibling account'
    );
    is_deeply(
        $res->{error}->{details},
        {
            accounts => {
                $loginid => {
                    balance  => "1.00000000",
                    currency => 'BTC'
                }}
        },
        'Correct array in details'
    );
    is($test_client->account->balance, '0.00', 'CR (USD) has no balance');
    ok(!$test_client->status->disabled,   'CR account is not disabled');
    ok(!$test_client_2->status->disabled, 'Sibling account is also not disabled');

    # Test with siblings account (has balance)
    $payment_handler->($test_client_2, -1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    $test_client_vr = BOM::User::Client->new({loginid => $test_client_vr->loginid});
    $test_client    = BOM::User::Client->new({loginid => $test_client->loginid});
    $test_client_2  = BOM::User::Client->new({loginid => $test_client_2->loginid});

    my $disabled_hashref = $test_client_2->status->disabled;

    is($res->{status},                  1,                     'Successfully received request');
    is($disabled_hashref->{reason},     $args->{reason},       'Correct message for reason');
    is($disabled_hashref->{staff_name}, $test_client->loginid, 'Correct loginid');
    ok($test_client_vr->status->disabled, 'Virtual account disabled');
    ok($test_client->status->disabled,    'CR account disabled');
};

$method = 'set_financial_assessment';
subtest $method => sub {
    my $args = {
        "set_financial_assessment"             => 1,
        "forex_trading_experience"             => "Over 3 years",                                     # +2
        "forex_trading_frequency"              => "0-5 transactions in the past 12 months",           # +0
        "binary_options_trading_experience"    => "1-2 years",                                        # +1
        "binary_options_trading_frequency"     => "40 transactions or more in the past 12 months",    # +2
        "cfd_trading_experience"               => "1-2 years",                                        # +1
        "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",           # +0
        "other_instruments_trading_experience" => "Over 3 years",                                     # +2
        "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",          # +1
        "employment_industry"                  => "Finance",                                          # +15
        "education_level"                      => "Secondary",                                        # +1
        "income_source"                        => "Self-Employed",                                    # +0
        "net_income"                           => '$25,000 - $50,000',                                # +1
        "estimated_worth"                      => '$100,000 - $250,000',                              # +1
        "occupation"                           => 'Managers',                                         # +0
        "employment_status"                    => "Self-Employed",                                    # +0
        "source_of_wealth"                     => "Company Ownership",                                # +0
        "account_turnover"                     => 'Less than $25,000',                                # +0
    };

    my $res = $c->tcall(
        $method,
        {
            token => $token_vr,
            args  => $args
        });
    is($res->{error}->{code}, 'PermissionDenied', "Not allowed for virtual account");

    $res = $c->tcall(
        $method,
        {
            args  => $args,
            token => $token1
        });
    is($res->{total_score}, 27, "Got correct total score");

    # test that setting this for one client also sets it for client with different landing company
    is($c->tcall('get_financial_assessment', {token => $token_mlt})->{source_of_wealth}, undef, "Financial assessment not set for MLT client");
    is($c->tcall('get_financial_assessment', {token => $token_mf})->{source_of_wealth},  undef, "Financial assessment not set for MF clinet");

    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token_mf
        });

    is($c->tcall('get_financial_assessment', {token => $token_mf})->{source_of_wealth}, "Company Ownership",
        "Financial assessment set for MF client");
    is(
        $c->tcall('get_financial_assessment', {token => $token_mlt})->{source_of_wealth},
        "Company Ownership",
        "Financial assessment set for MLT client"
    );

    # test that setting this for one client sets it for clients with same landing company
    is($c->tcall('get_financial_assessment', {token => $token_21})->{source_of_wealth},   undef, "Financial assessment not set for CR client");
    is($c->tcall('get_financial_assessment', {token => $token_cr_2})->{source_of_wealth}, undef, "Financial assessment not set for second CR clinet");
    mailbox_clear();

    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token_cr_2
        });
    is($c->tcall('get_financial_assessment', {token => $token_21})->{source_of_wealth}, "Company Ownership",
        "Financial assessment set for CR client");
    is(
        $c->tcall('get_financial_assessment', {token => $token_cr_2})->{source_of_wealth},
        "Company Ownership",
        "Financial assessment set for second CR client"
    );

    my $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/has submitted the assessment test/
    );
    ok(!$msg, 'no email for CR submitting FA');

};

$method = 'get_financial_assessment';
subtest $method => sub {
    my $args = {"get_financial_assessment" => 1};

    my $res = $c->tcall(
        $method,
        {
            token => $token_vr,
            args  => $args
        });
    is($res->{error}->{code}, 'PermissionDenied', "Not allowed for virtual account");

    $res = $c->tcall(
        $method,
        {
            args  => $args,
            token => $token1
        });
    is $res->{education_level}, 'Secondary', 'Got correct answer for assessment key';
};

# Second set financial assessment test to test for changes only. (in this case forex_trading_experience went from "Over 3 years" to "1-2 years")
$method = 'set_financial_assessment';
subtest $method => sub {
    my $args = {
        "set_financial_assessment"             => 1,
        "forex_trading_experience"             => "1-2 years",                                        # +1
        "forex_trading_frequency"              => "0-5 transactions in the past 12 months",           # +0
        "binary_options_trading_experience"    => "1-2 years",                                        # +1
        "binary_options_trading_frequency"     => "40 transactions or more in the past 12 months",    # +2
        "cfd_trading_experience"               => "1-2 years",                                        # +1
        "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",           # +0
        "other_instruments_trading_experience" => "Over 3 years",                                     # +2
        "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",          # +1
        "employment_industry"                  => "Finance",                                          # +15
        "education_level"                      => "Secondary",                                        # +1
        "income_source"                        => "Self-Employed",                                    # +0
        "net_income"                           => '$25,000 - $50,000',                                # +1
        "estimated_worth"                      => '$100,000 - $250,000',                              # +1
        "occupation"                           => 'Managers',                                         # +0
        "employment_status"                    => "Self-Employed",                                    # +0
        "source_of_wealth"                     => "Company Ownership",                                # +0
        "account_turnover"                     => 'Less than $25,000',                                # +0
    };

    mailbox_clear();
    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token1
        });
    is($c->tcall('get_financial_assessment', {token => $token1})->{forex_trading_experience}, "1-2 years", "forex_trading_experience changed");

    my $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/assessment test details have been updated/
    );
    ok($msg, 'send a email to compliance for MF after changing financial assessment');
    # make call again but with same arguments

    mailbox_clear();

    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token1
        });

    $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/assessment test details have been updated/
    );

    ok(!$msg, 'no email sent when no change');
};

$method = 'set_settings';
subtest $method => sub {

    my $emitted;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->mock(
        'emit',
        sub {
            my ($type, $data) = @_;
            $emitted->{$type} = $data;
        });

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
    my $mocked_client = Test::MockModule->new(ref($test_client));
    my $params        = {
        language   => 'EN',
        token      => $token_vr,
        client_ip  => '127.0.0.1',
        user_agent => 'agent',
        args       => {address1 => 'Address 1'}};
    # in normal case the vr client's residence should not be null, so I update is as '' to simulate null
    $test_client_vr->residence('');
    $test_client_vr->save();
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', "vr client can only update residence");
    # here I mocked function 'save' to simulate the db failure.
    $mocked_client->mock('save', sub { return undef });
    $params->{args}{residence} = 'zh';
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, our service is not available for your country of residence.',
        'return error if cannot save'
    );
    $mocked_client->unmock('save');
    # testing invalid residence, expecting save to fail
    my $result = $c->tcall($method, $params);
    is($result->{status}, undef, 'invalid residence should not be able to save');
    # testing valid residence, expecting save to pass
    $params->{args}{residence} = 'kr';
    $result = $c->tcall($method, $params);
    is($result->{status}, 1, 'vr account update residence successfully');
    $test_client_vr->load;
    isnt($test_client->address_1, 'Address 1', 'But vr account only update residence');

    # test real account
    $params->{token} = $token1;
    # Need to delete this parameter so this next call returns the error of interest
    delete $params->{args}{residence};
    my %full_args = (
        address_line_1  => 'address line 1',
        address_line_2  => 'address line 2',
        address_city    => 'address city',
        address_state   => 'BA',
        secret_question => 'testq',
        secret_answer   => 'testa',
        place_of_birth  => undef,
    );

    $params->{args}{residence} = 'kr';
    $full_args{account_opening_reason} = 'Income Earning';

    $params->{args} = {%{$params->{args}}, %full_args};
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', 'real account cannot update residence');
    $params->{args} = {%full_args};

    is($c->tcall($method, $params)->{error}{message_to_client}, 'Already have a secret_answer.', 'Cannot send secret_answer if already exists');
    delete $params->{args}{secret_answer};

    is($c->tcall($method, $params)->{error}{message_to_client}, 'Already have a secret_question.', 'Cannot send secret_question if already exists');
    delete $params->{args}{secret_question};

    delete $full_args{secret_question};
    delete $full_args{secret_answer};

    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
        'Correct tax error message'
    );

    $full_args{tax_residence}             = 'de';
    $full_args{tax_identification_number} = '111-222-333';

    $params->{args} = {%full_args};
    delete $params->{args}{address_line_1};

    $params->{args}{date_of_birth} = '1987-1-1';
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Your landing company does not allow date of birth to be changed.',
        'date_of_birth not allow changed'
    );
    delete $params->{args}{date_of_birth};

    $params->{args}{place_of_birth} = 'xx';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Please enter a valid place of birth.', 'place_of_birth no exists');
    $params->{args}{place_of_birth} = 'de';

    is($c->tcall($method, $params)->{status}, 1, 'can update without sending all required fields');
    ok($emitted->{sync_onfido_details}, 'event exists');

    my $event_data = delete $emitted->{sync_onfido_details};
    is($event_data->{loginid},          'MF90000000', 'Correct loginid');
    is($emitted->{sync_onfido_details}, undef,        'sync_onfido_details event does not exists');

    is($c->tcall($method, $params)->{status}, 1, 'can send set_settings with same value');
    {
        local $full_args{place_of_birth} = 'at';
        $params->{args} = {%full_args};

        is(
            $c->tcall($method, $params)->{error}{message_to_client},
            'Your landing company does not allow place of birth to be changed.',
            'cannot send place_of_birth with a different value'
        );
    }
    for my $tax_field (qw(tax_residence tax_identification_number)) {
        local $params->{args} = {
            $tax_field => '',
        };

        my $res = $c->tcall($method, $params);
        is($res->{error}{code}, 'PermissionDenied', $tax_field . ' cannot be removed once it has been set');
    }
    for my $restricted_country (qw(us ir hk my)) {
        local $params->{args} = {
            tax_residence             => $restricted_country,
            tax_identification_number => '111-222-543',
        };

        my $res = $c->tcall($method, $params);
        is($res->{error}{code}, 'RestrictedCountry', 'restricted country ' . $restricted_country . ' for tax residence is blocked as expected')
            or note explain $res;
    }
    # Testing the comma-separated list form of input separately
    for my $restricted_country (qw(us ir hk)) {
        local $params->{args} = {
            tax_residence             => "id,$restricted_country,my",
            tax_identification_number => '111-222-543',
        };

        my $res = $c->tcall($method, $params);
        is($res->{error}{code},
            'RestrictedCountry', 'one restricted country (' . $restricted_country . ') in list of tax residences is also blocked as expected')
            or note explain $res;
        like($res->{error}{message_to_client}, qr/"\Q\U$restricted_country"/, 'error message mentioned the country')
            or note explain $res->{error};
    }
    for my $unrestricted_country (qw(id ru)) {
        local $params->{args} = {
            tax_residence             => $unrestricted_country,
            tax_identification_number => '111-222-543',
        };

        my $res = $c->tcall($method, $params);
        is($res->{status}, 1, 'unrestricted country ' . $unrestricted_country . ' for tax residence is allowed') or note explain $res;
    }
    {
        local $full_args{account_opening_reason} = 'Hedging';
        $params->{args} = {%full_args};
        is(
            $c->tcall($method, $params)->{error}{message_to_client},
            'Your landing company does not allow account opening reason to be changed.',
            'cannot send account_opening_reason with a different value'
        );
    }

    $params->{args} = {%full_args};
    $mocked_client->mock('save', sub { return undef });
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your request.',
        'return error if cannot save'
    );
    $mocked_client->unmock_all;

    # add_note should send an email to support address,
    # but it is disabled when the test is running on travis-ci
    # so I mocked this function to check it is called.
    my $add_note_called;
    $mocked_client->mock('add_note', sub { $add_note_called = 1; });
    my $old_latest_environment = $test_client->latest_environment;
    mailbox_clear();
    $params->{args}->{email_consent} = 1;

    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    my $res = $c->tcall('get_settings', {token => $token1});
    is($res->{tax_identification_number}, $params->{args}{tax_identification_number}, "Check tax information");
    is($res->{tax_residence},             $params->{args}{tax_residence},             "Check tax information");

    ok($add_note_called, 'add_note is called, so the email should be sent to support address');

    subtest 'Check for citizenship value' => sub {

        subtest 'empty/unspecified' => sub {
            $params->{token} = $token_mx;
            $params->{args} = {%full_args, citizen => ''};
            is($c->tcall($method, $params)->{error}{message_to_client}, 'Citizenship is required.', 'empty value for citizenship');
        };

        $params->{token} = $token1;

        subtest 'invalid' => sub {
            $params->{args} = {%full_args, citizen => 'xx'};
            $test_client->citizen('');
            $test_client->save();
            is(
                $c->tcall($method, $params)->{error}{message_to_client},
                'Sorry, our service is not available for your country of citizenship.',
                'invalid value for citizenship'
            );
        };

        subtest 'different value' => sub {
            $params->{args} = {%full_args, citizen => 'bt'};
            $test_client->citizen('at');
            $test_client->save();
            is(
                $c->tcall($method, $params)->{error}{message_to_client},
                'Your landing company does not allow citizen to be changed.',
                'different value for citizenship'
            );
        };
        subtest 'restricted countries' => sub {
            for my $restricted_country (qw(us ir hk my)) {
                $params->{args} = {%full_args, citizen => $restricted_country};
                $test_client->citizen('');
                $test_client->save();
                is($c->tcall($method, $params)->{status}, 1, 'update successfully');
                is($c->tcall('get_settings', {token => $token1})->{citizen}, $restricted_country, "Restricted country value for citizenship");

            }
        };

    };
    $test_client->load();

    isnt($test_client->latest_environment, $old_latest_environment, "latest environment updated");

    my $subject = 'Change in account settings';
    my $msg     = mailbox_search(
        email   => $test_client->email,
        subject => qr/\Q$subject\E/
    );
    ok($msg, 'send a email to client');
    like($msg->{body}, qr/>address line 1, address line 2, address city, Bali/s, 'email content correct');
    mailbox_clear();

    $params->{args}->{request_professional_status} = 1;

    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    $subject = $test_loginid . ' requested for professional status';
    $msg     = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/\Q$subject\E/
    );
    ok($msg, 'send a email to client');
    is_deeply($msg->{to}, ['compliance@binary.com', 'support@binary.com'], 'email to address is ok');
    mailbox_clear();

    $res = $c->tcall('get_settings', {token => $token1});
    is($res->{request_professional_status}, 1, "Was able to request professional status");

    # test that postcode is optional for non-MX clients and required for MX clients
    $full_args{address_postcode} = '';

    $params->{args} = {%full_args};
    is($c->tcall($method, $params)->{status}, 1, 'postcode is optional for non-MX clients and can be set to null');

    $params->{token} = $token_mx;
    $params->{args}{account_opening_reason} = 'Income Earning';

    # setting account settings for one client also updates for clients that have a different landing company
    $params->{token} = $token_mlt;
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    is($c->tcall('get_settings', {token => $token_mlt})->{address_line_1}, "address line 1", "Was able to set settings for MLT client");
    is($c->tcall('get_settings', {token => $token_mf})->{address_line_1},  "address line 1", "Was able to set settings for MF client");

    # setting account settings for one client updates for all clients with the same landing company
    $params->{token} = $token_cr_2;
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    is($c->tcall('get_settings', {token => $token_21})->{address_line_1}, "address line 1", "Was able to set settings correctly for CR client");
    is(
        $c->tcall('get_settings', {token => $token_cr_2})->{address_line_1},
        "address line 1",
        "Was able to set settings correctly for second CR client"
    );
};

# set_self_exclusion && get_self_exclusion
$method = 'set_self_exclusion';
subtest 'get and set self_exclusion' => sub {
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

    my $params = {
        token => $token_vr,
        args  => {}};
    is($c->tcall($method, $params)->{error}{message_to_client}, "Permission denied.", 'vr client cannot set exclusion');

    $params->{token} = $token1;

    is($c->tcall($method, $params)->{error}{message_to_client}, "Please provide at least one self-exclusion setting.", "need one exclusion");

    $params->{args} = {
        set_self_exclusion => 1,
        max_balance        => 10000,
        max_open_bets      => 50,
        max_turnover       => undef,    # null should be OK to pass
        max_7day_losses    => 0,        # 0 is ok to pass but not saved
    };

    # Test for Maximum bets
    $params->{args}->{max_open_bets} = 120;

    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Please enter a number between 1 and 100.",
            'details'           => 'max_open_bets',
            'code'              => 'SetSelfExclusionError'
        });

    $params->{args}->{max_open_bets} = 50;

    # Test for Maximum balance
    $params->{args}->{max_balance} = 399999;
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Please enter a number between 0 and 300000.",
            'details'           => 'max_balance',
            'code'              => 'SetSelfExclusionError'
        });

    $params->{args}->{max_balance} = 10000;

    is($c->tcall($method, $params)->{status}, 1, "update self_exclusion ok");

    $params->{args}{max_balance} = 9999.999;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Input validation failed: max_balance.',
        'don\'t allow more than two decimals in max balance for this client'
    );
    $params->{args}{max_balance} = 9999.99;
    is($c->tcall($method, $params)->{status}, 1, 'allow two decimals in max balance');

    delete $params->{args};
    is_deeply(
        $c->tcall('get_self_exclusion', $params),
        {
            'max_open_bets' => '50',
            'max_balance'   => '9999.99'
        },
        'get self_exclusion ok'
    );

    # don't send previous required fields, should be okay
    $params->{args} = {
        set_self_exclusion => 1,
        max_30day_turnover => 100000
    };
    is($c->tcall($method, $params)->{status}, 1, "update self_exclusion ok");

    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440 * 42 + 1,
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Session duration limit cannot be more than 6 weeks.",
            'details'           => 'session_duration_limit',
            'code'              => 'SetSelfExclusionError'
        });
    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        exclude_until          => '2010-01-01'
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Exclude time must be after today.",
            'details'           => 'exclude_until',
            'code'              => 'SetSelfExclusionError'
        });
    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        exclude_until          => Date::Utility->new->plus_time_interval('3mo')->date_yyyymmdd
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Exclude time cannot be less than 6 months.",
            'details'           => 'exclude_until',
            'code'              => 'SetSelfExclusionError'
        });

    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        exclude_until          => Date::Utility->new->plus_time_interval('6y')->date_yyyymmdd
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Exclude time cannot be for more than five years.",
            'details'           => 'exclude_until',
            'code'              => 'SetSelfExclusionError'
        });

    # timeout_until
    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        timeout_until          => time() - 86400,
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Timeout time must be greater than current time.",
            'details'           => 'timeout_until',
            'code'              => 'SetSelfExclusionError'
        });

    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        timeout_until          => time() + 86400 * 7 * 10,    # max is 6 weeks
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Timeout time cannot be more than 6 weeks.",
            'details'           => 'timeout_until',
            'code'              => 'SetSelfExclusionError'
        });

    mailbox_clear();
    my $exclude_until = Date::Utility->new->plus_time_interval('7mo')->date_yyyymmdd;
    my $timeout_until = Date::Utility->new->plus_time_interval('1d');
    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9998,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        exclude_until          => $exclude_until,
        timeout_until          => $timeout_until->epoch,
    };
    is($c->tcall($method, $params)->{status}, 1, 'update self_exclusion ok');
    my $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/Client $test_loginid set self-exclusion limits/,    # debug => 1,
    );
    ok($msg, "msg sent to marketing and compliance email");
    is_deeply($msg->{to}, ['compliance@binary.com', 'marketing@binary.com'], "msg sent to marketing and compliance email");
    like($msg->{body}, qr/.*Exclude from website until/s, 'email content is ok');

    like(
        $c->tcall($method, $params)->{error}->{message_to_client},
        qr/Sorry, but you have self-excluded yourself from the website until/,
        'Self excluded client cannot access set self exclusion'
    );

    delete $params->{args};
    ok($c->tcall('get_self_exclusion', $params), 'Get response even if client is self excluded');

    $test_client->load();
    my $self_excl = $test_client->get_self_exclusion;
    is $self_excl->max_balance, 9998, 'set correct in db';
    is $self_excl->exclude_until, $exclude_until . 'T00:00:00', 'exclude_until in db is right';
    is $self_excl->timeout_until, $timeout_until->epoch, 'timeout_until is right';
    is $self_excl->session_duration_limit, 1440, 'all good';

    ## Section: Check self-exclusion notification emails for compliance, related to
    ##  clients under Binary (Europe) Limited, are sent under correct circumstances.
    mailbox_clear();

    ## Set some limits, and no email should be sent, because no MT5 account has
    ##   been opened yet.
    $params->{token} = $token_mlt;
    ##  clients under Binary (Europe) Limited, are sent under correct circumstances.

    ## Set some limits, and no email should be sent, because no MT5 account has
    ##   been opened yet.
    $params->{token} = $token_mlt;
    $params->{args}  = {
        set_self_exclusion     => 1,
        max_balance            => 9998,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
    };
    is($c->tcall($method, $params)->{status}, 1, 'update self_exclusion ok');
    $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/Client $test_client_mlt_loginid set self-exclusion limits/
    );
    ok(!$msg, 'No email for MLT client limits without MT5 accounts');

    ## Open an MT5 account
    # Mocked account details
    # This hash shared between three files, and should be kept in-sync to avoid test failures
    #   t/BOM/RPC/30_mt5.t
    #   t/BOM/RPC/05_accounts.t
    #   t/lib/mock_binary_mt5.pl
    my %DETAILS = (
        login    => '123454321',
        password => 'Efgh4567',
        email    => 'test.account@binary.com',
        name     => 'Test',
        group    => 'real\svg',
        country  => 'Malta',
        balance  => '1234',
    );
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

    my $mt5_params = {
        language => 'EN',
        token    => $token_mlt,
        args     => {
            account_type   => 'gaming',
            country        => 'mt',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password},
            leverage       => 100,
        },
    };
    my $mt5_loginid = $c->tcall('mt5_new_account', $mt5_params)->{login};
    is($mt5_loginid, $DETAILS{login}, 'MT5 loginid is correct: ' . $mt5_loginid);

    ## Verify an email was sent after opening an MT5 account, since user has
    ##  limits currently in place.
    $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/Client $test_client_mlt_loginid set self-exclusion limits/
    );
    ok($msg, 'Email for MLT client limits with MT5 accounts');
    is_deeply($msg->{to}, ['compliance@binary.com', 'marketing@binary.com', 'x-acc@binary.com'], 'email to address ok');
    like($msg->{body}, qr/MT$mt5_loginid/, 'email content is ok');

    ## Set some limits again, and another email should be sent to compliance listing
    ##  the new limitations since an MT5 account is open.
    mailbox_clear();
    is($c->tcall($method, $params)->{status}, 1, 'update self_exclusion ok');
    $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/Client $test_client_mlt_loginid set self-exclusion limits/
    );
    ok($msg, 'Email for MLT client limits with MT5 accounts');
    is_deeply($msg->{to}, ['compliance@binary.com', 'marketing@binary.com', 'x-acc@binary.com'], 'email to address ok');
    like($msg->{body}, qr/MT$mt5_loginid/, 'email content is ok');
};

# Recursively get values from nested hashes
sub get_values {
    my $in = shift;
    my @vals;
    for my $v (values %$in) {
        push @vals => ref $v eq 'HASH' ? get_values($v) : $v;
    }
    return @vals;
}

done_testing();
