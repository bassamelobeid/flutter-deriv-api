use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::QueueClient;
use Format::Util::Numbers                        qw/formatnumber/;
use Scalar::Util                                 qw/looks_like_number/;
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Platform::Token::API;
use BOM::Test::Helper::Token;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

BOM::Test::Helper::Token::cleanup_redis_tokens();

# init db
my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MF',
    binary_user_id => $user->id,
});

$test_client->email($email);
$test_client->save;

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;

$user->add_client($test_client);
$user->add_client($test_client_vr);

my $test_loginid = $test_client->loginid;

my $user_cr = BOM::User->create(
    email    => 'sample@binary.com',
    password => $hash_pwd
);

my $test_client_cr_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'VRTC',
    binary_user_id => $user_cr->id,
});

$test_client_cr_vr->email('sample@binary.com');
$test_client_cr_vr->save;

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    citizen        => 'at',
    binary_user_id => $user_cr->id,
});
$test_client_cr->email('sample@binary.com');
$test_client_cr->set_default_account('USD');
$test_client_cr->save;

my $test_client_cr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user_cr->id,
});
$test_client_cr_2->email('sample@binary.com');
$test_client_cr_2->save;

$user_cr->add_client($test_client_cr_vr);
$user_cr->add_client($test_client_cr);
$user_cr->add_client($test_client_cr_2);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $test_client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
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
$test_client_vr_2->set_default_account('USD');
$test_client_vr_2->save;

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
$user_mlt_mf->add_client($test_client_vr_2);
$user_mlt_mf->add_client($test_client_mlt);
$user_mlt_mf->add_client($test_client_mf);

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_loginid,                  'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_with_txn = $m->create_token($test_client_2->loginid,        'test token');

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

$test_client_2->payment_free_gift(
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

my $c = Test::BOM::RPC::QueueClient->new;

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
    client              => $test_client_2,
    contract_parameters => $contract_expired,
    price               => 100,
    amount_type         => 'stake',
    purchase_date       => $now->epoch - 101,
});

$txn->buy(skip_validation => 1);

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
        client              => $test_client_2,
        contract_parameters => $contract_expired,
        price               => 100,
        payout              => 200,
        amount_type         => 'stake',
        purchase_date       => $R_100_start->epoch - 101,

});
$txn->buy(skip_validation => 1);

my $method = 'profit_table';
subtest 'profit table' => sub {
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

    #create a new transaction of type CALL for test
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
        client              => $test_client_2,
        contract_parameters => $contract_expired,
        price               => 100,
        amount_type         => 'stake',
        purchase_date       => $now->epoch - 101,
    });

    $txn->buy(skip_validation => 1);

    my $result = $c->tcall($method, {token => $token_with_txn});
    is($result->{count}, 3, 'the CALL transaction is sold so _sell_expired_contracts is called');

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $test_client_2->loginid,
            currency_code  => $test_client_2->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $test_client_2->loginid,
                    operation      => 'replica',
                }
            )->db,
        });
    my $args    = {};
    my $data    = $fmb_dm->get_sold_bets_of_account($args);
    my $expect0 = {
        'contract_id'    => $txn->contract_id,
        'transaction_id' => $txn->transaction_id,
        'payout'         => formatnumber('price', $test_client_2->currency, $txn->contract->payout),
        'buy_price'      => '100.00',
        'purchase_time'  => Date::Utility->new($data->[1]{purchase_time})->epoch,
        'sell_price'     => '100.00',
        'sell_time'      => Date::Utility->new($data->[1]{sell_time})->epoch,
        'app_id'         => undef
    };
    is_deeply($result->{transactions}[1], $expect0, 'result for CALL is correct');
    $expect0->{longcode}          = 'Win payout if Volatility 50 Index is strictly higher than entry spot at 50 seconds after contract start time.';
    $expect0->{shortcode}         = $data->[1]{short_code};
    $expect0->{contract_type}     = $data->[1]{bet_type};
    $expect0->{underlying_symbol} = 'R_50';
    $expect0->{duration_type}     = 'seconds';
    $result                       = $c->tcall(
        $method,
        {
            token => $token_with_txn,
            args  => {description => 1}});

    is_deeply($result->{transactions}[1], $expect0, 'the result for CALL with description ok');
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

    # create a new transaction of type MULTUP for test
    $contract_expired = {
        underlying   => $underlying,
        bet_type     => 'MULTUP',
        currency     => 'USD',
        stake        => 100,
        date_start   => $now->epoch - 110,
        date_pricing => $now->epoch - 110,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        multiplier   => 20,
    };

    $txn = BOM::Transaction->new({
        client              => $test_client_2,
        contract_parameters => $contract_expired,
        price               => 100,
        amount_type         => 'stake',
        purchase_date       => $now->epoch - 111,
    });

    $txn->buy(skip_validation => 1);
    $txn->sell(skip_validation => 1);

    $result = $c->tcall(
        $method,
        {
            token => $token_with_txn,
            args  => {description => 1}});
    is($result->{count}, 4, 'the MULTUP transaction is sold so _sell_expired_contracts is called');

    $data = $fmb_dm->get_sold_bets_of_account($args);

    my $expect1 = {
        'contract_id'       => $txn->contract_id,
        'transaction_id'    => $data->[3]{txn_id},
        'payout'            => formatnumber('price', $test_client_2->currency, $txn->contract->payout),
        'buy_price'         => '100.00',
        'purchase_time'     => Date::Utility->new($data->[3]{purchase_time})->epoch,
        'sell_price'        => '100.00',
        'sell_time'         => Date::Utility->new($data->[3]{sell_time})->epoch,
        'underlying_symbol' => 'R_50',
        'app_id'            => undef,
        'shortcode'         => $data->[3]{short_code},
        'longcode'          =>
            "If you select 'Up', your total profit/loss will be the percentage increase in Volatility 50 Index, multiplied by 2000, minus commissions.",
        'contract_type' => 'MULTUP',
        'duration_type' => 'days',
        'multiplier'    => '20'
    };
    is_deeply($result->{transactions}[3], $expect1, 'result for MULTUP is correct');

    # create a new transaction of type MULTDOWN with deal cancellation for test
    $contract_expired = {
        underlying   => $underlying,
        bet_type     => 'MULTDOWN',
        currency     => 'USD',
        stake        => 10,
        date_start   => $now->epoch - 120,
        date_pricing => $now->epoch - 120,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        multiplier   => 50,
        cancellation => '30m'
    };

    $txn = BOM::Transaction->new({
        client              => $test_client_2,
        contract_parameters => $contract_expired,
        price               => 10,
        amount_type         => 'stake',
        purchase_date       => $now->epoch - 121,
    });

    $txn->buy(skip_validation => 1);
    $txn->sell(skip_validation => 1);

    $result = $c->tcall(
        $method,
        {
            token => $token_with_txn,
            args  => {description => 1}});
    is($result->{count}, 5, 'the MULTDOWN transaction is sold so _sell_expired_contracts is called');

    $data = $fmb_dm->get_sold_bets_of_account($args);

    my $expect2 = {
        'contract_id'       => $txn->contract_id,
        'transaction_id'    => $data->[4]{txn_id},
        'payout'            => formatnumber('price', $test_client_2->currency, $txn->contract->payout),
        'buy_price'         => '10.00',
        'purchase_time'     => Date::Utility->new($data->[4]{purchase_time})->epoch,
        'sell_price'        => '10.00',
        'sell_time'         => Date::Utility->new($data->[4]{sell_time})->epoch,
        'underlying_symbol' => 'R_50',
        'app_id'            => undef,
        'shortcode'         => $data->[4]{short_code},
        'longcode'          =>
            "If you select 'Down', your total profit/loss will be the percentage decrease in Volatility 50 Index, multiplied by 500, minus commissions.",
        'contract_type'              => 'MULTDOWN',
        'duration_type'              => 'days',
        'multiplier'                 => '50',
        'deal_cancellation_duration' => '30m'
    };
    is_deeply($result->{transactions}[4], $expect2, 'result for MULTDOWN is correct');

    # create a new transaction of type ACCU for test
    $contract_expired = {
        underlying   => $underlying,
        bet_type     => 'ACCU',
        currency     => 'USD',
        stake        => 100,
        date_start   => $now->epoch - 130,
        date_pricing => $now->epoch - 130,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        growth_rate  => 0.05
    };

    $txn = BOM::Transaction->new({
        client              => $test_client_2,
        contract_parameters => $contract_expired,
        price               => 100,
        amount_type         => 'stake',
        purchase_date       => $now->epoch - 131,
    });

    $txn->buy(skip_validation => 1);
    $txn->sell(skip_validation => 1);

    $result = $c->tcall(
        $method,
        {
            token => $token_with_txn,
            args  => {description => 1}});
    is($result->{count}, 6, 'the ACCU transaction is sold so _sell_expired_contracts is called');

    $data = $fmb_dm->get_sold_bets_of_account($args);

    my $expect3 = {
        'contract_id'       => $txn->contract_id,
        'transaction_id'    => $data->[5]{txn_id},
        'payout'            => formatnumber('price', $test_client_2->currency, $txn->contract->payout),
        'buy_price'         => '100.00',
        'purchase_time'     => Date::Utility->new($data->[5]{purchase_time})->epoch,
        'sell_price'        => '100.00',
        'sell_time'         => Date::Utility->new($data->[5]{sell_time})->epoch,
        'underlying_symbol' => 'R_50',
        'app_id'            => undef,
        'shortcode'         => $data->[5]{short_code},
        'longcode'          => re(
            'After the entry spot tick, your stake will grow continuously by 5% for every tick that the spot price remains within the ± 0.[0-9]+% from the previous spot price.'
        ),
        'contract_type' => 'ACCU',
        'duration_type' => undef,
        'growth_rate'   => 0.05
    };
    cmp_deeply($result->{transactions}[5], $expect3, 'result for ACCU is correct');

    #create a new transaction of type PUT for test
    $contract_expired = {
        underlying   => $underlying,
        bet_type     => 'PUT',
        currency     => 'USD',
        stake        => 15,
        date_start   => $now->epoch - 100,
        date_expiry  => $now->epoch - 50,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        barrier      => 'S0P',
    };

    $txn = BOM::Transaction->new({
        client              => $test_client_2,
        contract_parameters => $contract_expired,
        price               => 115,
        amount_type         => 'stake',
        purchase_date       => $now->epoch - 101,
    });

    $txn->buy(skip_validation => 1);
    is(
        $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {
                    contract_type => ['PUT'],
                }}
        )->{count},
        1,
        'There is one contract of type PUT'
    );
    is(
        $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {
                    contract_type => ['CALL'],
                }}
        )->{count},
        3,
        'There are three contracts of type CALL'
    );
    is(
        $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {
                    contract_type => ['CALL', 'PUT'],
                }}
        )->{count},
        4,
        'There are four contracts of type CALL and PUT'
    );
    is(
        $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {
                    contract_type => ['UPORDOWN'],
                }}
        )->{count},
        0,
        'There is no contract of type UPORDOWN'
    );
    is(
        $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {
                    contract_type => [],
                }}
        )->{count},
        7,
        'All contracts are returned if the given array is empty'
    );
};

done_testing();
