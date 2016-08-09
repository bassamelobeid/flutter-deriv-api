use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use JSON;
use Encode qw(encode);
use Email::Folder::Search;

use Price::Calculator qw/formatnumber/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Database::Model::AccessToken;
use BOM::RPC::v3::Utility;
use BOM::Platform::Password;
use BOM::Platform::User;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

package MojoX::JSON::RPC::Client;
use Data::Dumper;
use Test::Most;

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
my $hash_pwd    = BOM::Platform::Password::hashpw($password);
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
my $user         = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_loginid});
$user->add_loginid({loginid => $test_client_vr->loginid});
$user->save;
my $mailbox = Email::Folder::Search->new('/tmp/default.mailbox');
$mailbox->init;

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_cr->email('sample@binary.com');
$test_client_cr->set_default_account('USD');
$test_client_cr->save;

my $user_cr = BOM::Platform::User->create(
    email    => 'sample@binary.com',
    password => $hash_pwd
);
$user_cr->save;
$user_cr->add_loginid({loginid => $test_client_cr->loginid});
$user_cr->save;

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $test_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->set_status('disabled', 1, 'test disabled');
$test_client_disabled->save();

my $japan_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'JP',
});

my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
});
$test_client_mx->email($email);

my $m              = BOM::Database::Model::AccessToken->new;
my $token1         = $m->create_token($test_loginid, 'test token');
my $token_21       = $m->create_token($test_client_cr->loginid, 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_vr       = $m->create_token($test_client_vr->loginid, 'test token');
my $token_with_txn = $m->create_token($test_client2->loginid, 'test token');
my $token_japan    = $m->create_token($japan_client->loginid, 'test token');
my $token_mx       = $m->create_token($test_client_mx->loginid, 'test token');

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
my $t = Test::Mojo->new('BOM::RPC');
my $c = MojoX::JSON::RPC::Client->new(ua => $t->app->ua);

my $method = 'payout_currencies';
subtest $method => sub {
    is_deeply($c->tcall($method, {token => '12345'}), [qw(USD EUR GBP AUD)], 'invalid token will get all currencies');
    is_deeply(
        $c->tcall(
            $method,
            {
                token => undef,
            }
        ),
        [qw(USD EUR GBP AUD)],
        'undefined token will get all currencies'
    );

    is_deeply($c->tcall($method, {token => $token_21}), ['USD'], "will return client's currency");
    is_deeply($c->tcall($method, {}), [qw(USD EUR GBP AUD)], "will return legal currencies if no token");
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
        $c->tcall($method, {args => {landing_company_details => 'nosuchcountry'}}),
        {
            error => {
                message_to_client => 'Unknown landing company.',
                code              => 'UnknownLandingCompany'
            }
        },
        "no such landing company"
    );
    is($c->tcall($method, {args => {landing_company_details => 'costarica'}})->{name}, 'Binary (C.R.) S.A.', "details result ok");
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
            token => $token_japan
        });
    is($res->{error}->{code}, 'PermissionDenied', "Not allowed for japan account");

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

    is_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status              => ['has_password'],
            risk_classification => 'low'
        },
        'status only has_password'
    );
    $test_client->set_status('tnc_approval', 'test staff', 1);
    $test_client->save();
    is_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status              => ['has_password'],
            risk_classification => 'low'
        },
        'tnc_approval is excluded, still status only has has_password'
    );

    # test 'financial_assessment_needed'
    $test_client->aml_risk_classification('high');
    $test_client->save();
    is_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status              => ['has_password', 'financial_assessment_needed'],
            risk_classification => 'high'
        },
        'financial_assessment_needed when client has not filled questionnaire'
    );

    # test when some questions are not answered
    my $data = {
        "forex_trading_experience" => {"answer" => ""},
        "forex_trading_frequency"  => {"answer" => ""},
    };
    encode_json $data;
    $test_client->financial_assessment({
        data            => encode_json $data,
        is_professional => 0
    });
    $test_client->save();
    is_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status              => ['has_password', 'financial_assessment_needed'],
            risk_classification => 'high'
        },
        'financial_assessment_needed when some questions are not answered'
    );

    # client has let some answers empty
    $data = {
        "commodities_trading_experience"       => {"answer" => ""},
        "commodities_trading_frequency"        => {"answer" => ""},
        "education_level"                      => {"answer" => ""},
        "estimated_worth"                      => {"answer" => '$100,000 - $250,000'},
        "employment_industry"                  => {"answer" => "Finance"},
        "forex_trading_experience"             => {"answer" => "Over 3 years"},
        "forex_trading_frequency"              => {"answer" => "0-5 transactions in the past 12 months"},
        "income_source"                        => {"answer" => "Self-Employed"},
        "indices_trading_experience"           => {"answer" => "Over 3 years"},
        "indices_trading_frequency"            => {"answer" => "40 transactions or more in the past 12 months"},
        "net_income"                           => {"answer" => '$25,000 - $50,000'},
        "occupation"                           => {"answer" => "Managers"},
        "other_derivatives_trading_experience" => {"answer" => "Over 3 years"},
        "other_derivatives_trading_frequency"  => {"answer" => "0-5 transactions in the past 12 months"},
        "other_instruments_trading_experience" => {"answer" => "Over 3 years"},
        "other_instruments_trading_frequency"  => {"answer" => "6-10 transactions in the past 12 months"},
        "stocks_trading_experience"            => {"answer" => "1-2 years"},
        "stocks_trading_frequency"             => {"answer" => "0-5 transactions in the past 12 months"},
        "account_turnover"                     => {"answer" => 'Less than $25,000'},
        "account_opening_reason"               => {"answer" => "Experience"}
    };


    $test_client->financial_assessment({
        data            => encode_json $data,
        is_professional => 0
    });
    $test_client->save();
    is_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status              => ['has_password', 'financial_assessment_needed'],
            risk_classification => 'high'
        },
        'financial_assessment_needed when some answers are empty'
    );

    $data = {
        "commodities_trading_experience"       => {"answer" => "1-2 years"},
        "commodities_trading_frequency"        => {"answer" => "0-5 transactions in the past 12 months"},
        "education_level"                      => {"answer" => "Secondary"},
        "estimated_worth"                      => {"answer" => '$100,000 - $250,000'},
        "employment_industry"                  => {"answer" => "Finance"},
        "forex_trading_experience"             => {"answer" => "Over 3 years"},
        "forex_trading_frequency"              => {"answer" => "0-5 transactions in the past 12 months"},
        "income_source"                        => {"answer" => "Self-Employed"},
        "indices_trading_experience"           => {"answer" => "Over 3 years"},
        "indices_trading_frequency"            => {"answer" => "40 transactions or more in the past 12 months"},
        "net_income"                           => {"answer" => '$25,000 - $50,000'},
        "occupation"                           => {"answer" => "Managers"},
        "other_derivatives_trading_experience" => {"answer" => "Over 3 years"},
        "other_derivatives_trading_frequency"  => {"answer" => "0-5 transactions in the past 12 months"},
        "other_instruments_trading_experience" => {"answer" => "Over 3 years"},
        "other_instruments_trading_frequency"  => {"answer" => "6-10 transactions in the past 12 months"},
        "stocks_trading_experience"            => {"answer" => "1-2 years"},
        "stocks_trading_frequency"             => {"answer" => "0-5 transactions in the past 12 months"},
        "account_turnover"                     => {"answer" => 'Less than $25,000'},
        "account_opening_reason"               => {"answer" => "Experience"}
    };
    # financial assessment is not needed when all questions is answered
    $test_client->financial_assessment({
        data            => encode_json $data,
        is_professional => 0
    });
    $test_client->save();
    is_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status              => ['has_password'],
            risk_classification => 'high'
        },
        'financial_assessment_needed should not present when questions are answered properly'
    );

    # reset the risk classification for the following test
    $test_client->aml_risk_classification('low');
    $test_client->financial_assessment({
        data            => undef,
        is_professional => 0
    });

    $test_client->set_authentication('ID_DOCUMENT')->status('pass');
    $test_client->save;
    is_deeply(
        $c->tcall($method, {token => $token1}),
        {
            status              => ['authenticated', 'has_password'],
            risk_classification => 'low'
        },
        'ok, authenticated'
    );

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
        'Password is not strong enough.',
        'Password is not strong enough.',
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
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Password is not strong enough.');
    my $new_password = 'Fsfjxljfwkls3@fs9';
    $params->{args}{new_password} = $new_password;
    $mailbox->clear;
    is($c->tcall($method, $params)->{status}, 1, 'update password correctly');
    my $subject = 'Your password has been changed.';
    my @msgs    = $mailbox->search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok(@msgs, "email received");
    $user->load;
    isnt($user->password, $hash_pwd, 'user password updated');
    $test_client->load;
    isnt($user->password, $hash_pwd, 'client password updated');
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
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Password is not strong enough.', 'check strong');
    $params->{args}{lock_password} = $tmp_new_password;

    $mailbox->clear;
    # here I mocked function 'save' to simulate the db failure.
    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock('save', sub { return undef });
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your account.',
        'return error if cannot save password'
    );
    $mocked_client->unmock_all;

    is($c->tcall($method, $params)->{status}, 1, 'set password success');
    my $subject = 'Cashier password updated';
    my @msgs    = $mailbox->search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok(@msgs, "email received");

    # test unlock
    $test_client->cashier_setting_password('');
    $test_client->save;
    delete $params->{args}{lock_password};
    $params->{args}{unlock_password} = '123456';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Your cashier was not locked.', 'return error if not locked');

    $mailbox->clear;
    $test_client->cashier_setting_password(BOM::Platform::Password::hashpw($tmp_password));
    $test_client->save;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, you have entered an incorrect cashier password',
        'return error if not correct'
    );
    $subject = 'Failed attempt to unlock cashier section';
    @msgs    = $mailbox->search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok(@msgs, "email received");

    # here I mocked function 'save' to simulate the db failure.
    $mocked_client->mock('save', sub { return undef });
    $params->{args}{unlock_password} = $tmp_password;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your account.',
        'return error if cannot save'
    );
    $mocked_client->unmock_all;

    $mailbox->clear;
    is($c->tcall($method, $params)->{status}, 0, 'unlock password ok');
    $test_client->load;
    ok(!$test_client->cashier_setting_password, 'Cashier password unset');
    $subject = 'Cashier password updated';
    @msgs    = $mailbox->search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok(@msgs, "email received");
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
        });

    $params->{token} = $token1;
    $test_client->set_status('tnc_approval', 'system', 1);
    $test_client->save;
    is($c->tcall($method, $params)->{client_tnc_status}, 1, 'tnc status set');
    $params->{token} = $token_vr;
    is_deeply(
        $c->tcall($method, $params),
        {
            'email'         => 'abc@binary.com',
            'country'       => 'Indonesia',
            'country_code'  => 'id',
            'email_consent' => '0'
        },
        'vr client return less messages'
    );
};

$method = 'set_financial_assessment';
subtest $method => sub {
    my $args = {
        "set_financial_assessment"             => 1,
        "forex_trading_experience"             => "Over 3 years",
        "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
        "indices_trading_experience"           => "1-2 years",
        "indices_trading_frequency"            => "40 transactions or more in the past 12 months",
        "commodities_trading_experience"       => "1-2 years",
        "commodities_trading_frequency"        => "0-5 transactions in the past 12 months",
        "stocks_trading_experience"            => "1-2 years",
        "stocks_trading_frequency"             => "0-5 transactions in the past 12 months",
        "other_derivatives_trading_experience" => "Over 3 years",
        "other_derivatives_trading_frequency"  => "0-5 transactions in the past 12 months",
        "other_instruments_trading_experience" => "Over 3 years",
        "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",
        "employment_industry"                  => "Finance",
        "education_level"                      => "Secondary",
        "income_source"                        => "Self-Employed",
        "net_income"                           => '$25,000 - $50,000',
        "estimated_worth"                      => '$100,000 - $250,000',
        "occupation"                           => 'Managers'
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
            token => $token_japan
        });
    is($res->{error}->{code}, 'PermissionDenied', "Not allowed for japan account");

    $res = $c->tcall(
        $method,
        {
            args  => $args,
            token => $token1
        });
    cmp_ok($res->{score}, "<", 60, "Got correct score");
    is($res->{is_professional}, 0, "As score is less than 60 so its marked as not professional");
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
    cmp_ok($res->{score}, "==", 30, "Got correct score");
    is $res->{education_level}, 'Secondary', 'Got correct answer for assessment key';
};

$method = 'set_settings';
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
    my %full_args = (
        address_line_1   => 'address line 1',
        address_line_2   => 'address line 2',
        address_city     => 'address city',
        address_state    => 'address state',
        address_postcode => '12345',
        phone            => '2345678',
    );
    $params->{args} = {%{$params->{args}}, %full_args};
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', 'real account cannot update residence');

    $params->{args} = {%full_args};

    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
        'Correct tax error message'
    );

    $full_args{tax_residence}             = 'de';
    $full_args{tax_identification_number} = '111-222-333';

    $params->{args} = {%full_args};
    delete $params->{args}{address_line_1};
    is($c->tcall($method, $params)->{status}, 1, 'can update without sending all required fields');

    $params->{args} = {%full_args};
    $mocked_client->mock('save', sub { return undef });
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your account.',
        'return error if cannot save'
    );
    $mocked_client->unmock_all;
    # add_note should send an email to support address,
    # but it is disabled when the test is running on travis-ci
    # so I mocked this function to check it is called.
    my $add_note_called;
    $mocked_client->mock('add_note', sub { $add_note_called = 1 });
    my $old_latest_environment = $test_client->latest_environment;
    $mailbox->clear;
    $params->{args}->{email_consent} = 1;

    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    my $res = $c->tcall('get_settings', {token => $token1});
    is($res->{tax_identification_number}, $params->{args}{tax_identification_number}, "Check tax information");
    is($res->{tax_residence},             $params->{args}{tax_residence},             "Check tax information");

    ok($add_note_called, 'add_note is called, so the email should be sent to support address');
    $test_client->load();
    isnt($test_client->latest_environment, $old_latest_environment, "latest environment updated");
    my $subject = 'Change in account settings';
    my @msgs    = $mailbox->search(
        email   => $test_client->email,
        subject => qr/\Q$subject\E/
    );
    ok(@msgs, 'send a email to client');
    like($msgs[0]{body}, qr/>address line 1, address line 2, address city, address state, 12345, Indonesia/s, 'email content correct');

    is($c->tcall('get_settings', {token => $token1})->{email_consent}, 1, "Was able to set email consent correctly");

    # test that postcode is optional for non-MX clients and required for MX clients
    $full_args{address_postcode} = '';

    $params->{args} = {%full_args};
    is($c->tcall($method, $params)->{status}, 1, 'postcode is optional for non-MX clients and can be set to null');

    $params->{token} = $token_mx;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Input validation failed: address_postcode',
        'postcode is required for MX clients and cannot be set to null'
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
        max_open_bets      => 100,
        max_turnover       => undef,    # null should be OK to pass
        max_7day_losses    => 0,        # 0 is ok to pass but not saved
    };
    is($c->tcall($method, $params)->{status}, 1, "update self_exclusion ok");
    delete $params->{args};
    is_deeply(
        $c->tcall('get_self_exclusion', $params),
        {
            'max_open_bets' => '100',
            'max_balance'   => '10000'
        },
        'get self_exclusion ok'
    );

    $params->{args} = {
        set_self_exclusion => 1,
        max_balance        => 10001,
        max_turnover       => 1000,
        max_open_bets      => 100,
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Please enter a number between 0 and 10000.",
            'details'           => 'max_balance',
            'code'              => 'SetSelfExclusionError'
        });

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
        max_open_bets          => 100,
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
        max_open_bets          => 100,
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
        max_open_bets          => 100,
        session_duration_limit => 1440,
        exclude_until          => DateTime->now()->add(months => 3)->ymd
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
        max_open_bets          => 100,
        session_duration_limit => 1440,
        exclude_until          => DateTime->now()->add(years => 6)->ymd
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
        max_open_bets          => 100,
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
        max_open_bets          => 100,
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

    $mailbox->clear;
    my $exclude_until = DateTime->now()->add(months => 7)->ymd;
    my $timeout_until = DateTime->now()->add(days   => 1);
    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9998,
        max_turnover           => 1000,
        max_open_bets          => 100,
        session_duration_limit => 1440,
        exclude_until          => $exclude_until,
        timeout_until          => $timeout_until->epoch,
    };
    is($c->tcall($method, $params)->{status}, 1, 'update self_exclusion ok');
    my @msgs = $mailbox->search(
        email   => 'compliance@binary.com,support@binary.com',
        subject => qr/Client set self-exclusion limits/
    );
    ok(@msgs, "msg sent to support email");
    like($msgs[0]{body}, qr/Maximum number of open positions: 100.*Exclude from website until/s, 'email content is ok');

    delete $params->{args};
    like(
        $c->tcall('get_self_exclusion', $params)->{error}{message_to_client},
        qr/Sorry, you have excluded yourself until/,
        'this client has self excluded'
    );

    $test_client->load();
    my $self_excl = $test_client->get_self_exclusion;
    is $self_excl->max_balance, 9998, 'set correct in db';
    is $self_excl->exclude_until, $exclude_until . 'T00:00:00', 'exclude_until in db is right';
    is $self_excl->timeout_until, $timeout_until->epoch, 'timeout_until is right';
    is $self_excl->session_duration_limit, 1440, 'all good';
};

done_testing();
