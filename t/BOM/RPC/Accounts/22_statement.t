use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::User::Password;
use BOM::User;
use BOM::Platform::Token::API;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Test::Helper::Token;

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

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_loginid, 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_with_txn = $m->create_token($test_client_mf->loginid, 'test token');

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

$test_client_mf->payment_free_gift(
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

my $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
my $c = Test::BOM::RPC::Client->new(ua => $t->app->ua);

my $method = 'statement';
subtest 'statement' => sub {
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
    
    is($c->tcall($method, {token => $token})->{count}, 0, 'have 0 statements if no default account');
    
    $test_client->account('USD');
    is($c->tcall($method, {token => $token})->{count}, 0, 'have 0 statements if no transactions');

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
        client              => $test_client_mf,
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
    my $txns = BOM::Transaction::History::get_transaction_history({ client => $test_client_mf });
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
            client              => $test_client_mf,
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
    $txns = BOM::Transaction::History::get_transaction_history({ client => $test_client_mf });        
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

    subtest 'sorting and params' => sub {
        my $account = $test_client_mf->account;
        my %tx_params = (
            payment_gateway_code => 'free_gift',
            payment_type_code    => 'free_gift',
            status               => 'OK',
            staff_loginid        => 'test',
            remark               => 'test',
            account_id           => $account->id,
            source               => 1,
        );
        
        my $yesterday = Date::Utility->new->minus_time_interval('1d');
        $account->add_payment_transaction({
            amount               => 23,
            transaction_time     => $yesterday->datetime,
            %tx_params,
        });
        $result = $c->tcall($method, {token => $token_with_txn});
        cmp_ok($result->{transactions}[-1]{amount}, '==', 23, 'new transaction with old time is sorted to the end');
    
        my $tx_time = $test_client_mf->account->db->dbh->selectrow_array('select transaction_time from transaction.transaction where id = '. $result->{transactions}[0]{transaction_id});
        $account->add_payment_transaction({
            amount               => 24,
            transaction_time     => $tx_time,
            %tx_params,
        });
    
        $result = $c->tcall($method, {token => $token_with_txn});
        cmp_ok($result->{transactions}[0]{amount}, '==', 24, 'new transaction with same time is sorted to the start');
        
        my $limited_result = $c->tcall($method, {token => $token_with_txn, args => {limit => 3}});
        cmp_ok($limited_result->{transactions}[0]{transaction_id}, '==', $result->{transactions}[0]{transaction_id}, 'first item with limit');
        cmp_ok($limited_result->{transactions}[-1]{transaction_id},'==', $result->{transactions}[2]{transaction_id}, 'last item with limit');
        is ($limited_result->{transactions}->@*, 3, 'correct number of results for limit');
        
        my $offset_result = $c->tcall($method, {token => $token_with_txn, args => {offset => 3}});
        cmp_ok($offset_result->{transactions}[0]{transaction_id}, '==', $result->{transactions}[3]{transaction_id}, 'first item with offset');
        cmp_ok($offset_result->{transactions}[-1]{transaction_id}, '==', $result->{transactions}[-1]{transaction_id}, 'last item with offset');

        $result = $c->tcall($method, {token => $token_with_txn, args => { date_from => $yesterday->minus_time_interval('1d')->epoch, date_to => $yesterday->epoch }});
        cmp_deeply( $result, { count => 0, transactions => [] }, 'empty results for old date range');

        $result = $c->tcall($method, {token => $token_with_txn, args => { date_from => $yesterday->epoch, date_to => $yesterday->plus_time_interval('1s')->epoch }});
        is ($result->{transactions}->@*, 1, 'correct number of results for specific date range');
        cmp_ok($result->{transactions}[0]{amount}, '==', 23, 'expected result for specific date range');

        for my $expected ( [buy => 2], [sell => 2], [deposit=>3], [withdrawal=>0], [escrow=>0], [adjustment=>0], [virtual_credit=>0] ) {
            $result = $c->tcall($method, {token => $token_with_txn, args => { action_type => $expected->[0] }}); 
            is ($result->{transactions}->@*, $expected->[1], 'correct number of '.$expected->[0].' results');
        }
    };
};

# request report
$method = 'request_report';
subtest 'request report' => sub {

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

done_testing();
