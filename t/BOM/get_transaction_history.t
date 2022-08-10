use strict;
use warnings;
use utf8;

use BOM::Database::DataMapper::Transaction;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::User::Password;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::MarketData               qw(create_underlying);
use BOM::Platform::Context        qw (localize);
use BOM::Test::Helper::P2P;

use BOM::Transaction;
use BOM::Transaction::History qw(get_transaction_history);
use BOM::Transaction::Validation;

use Date::Utility;
use Data::Dumper;

use Test::MockModule;
use Test::Most;
use Test::Warn;

my $now = Date::Utility->new();
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => $now,
    }) for qw(JPY USD JPY-USD);

my $underlying = create_underlying('R_50');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => $now,
    });

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

# init db
my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->status->set("professional");
$test_client->status->set('age_verification', 'test_name', 'test_reason');
$test_client->email($email);
$test_client->save;

my $transac_param = {client => $test_client};

$test_client->set_default_account('USD');
$test_client->save();

my $res = get_transaction_history($transac_param);
ok !@$res, 'client doesnt have any transactions';

my $test_loginid = $test_client->loginid;
my $user         = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);

# deposit
$test_client->payment_free_gift(
    currency => 'USD',
    amount   => 50000,
    remark   => 'free gift',
);

# buy a contract now
my $contract = produce_contract({
    underlying   => $underlying,
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 1000,
    duration     => '15m',
    current_tick => $tick,
    entry_tick   => $tick,
    exit_tick    => $tick,
    barrier      => 'S0P',
});

my $txn = BOM::Transaction->new({
    client        => $test_client,
    contract      => $contract,
    price         => 514.00,
    payout        => $contract->payout,
    amount_type   => 'payout',
    source        => 19,
    purchase_date => $contract->date_start,
});
my $error = $txn->buy(skip_validation => 1);
is $error, undef, 'no error';

# buy expired contract
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

$txn = BOM::Transaction->new({
    client              => $test_client,
    contract_parameters => $contract_expired,
    price               => 100,
    amount_type         => 'stake',
    purchase_date       => $now->epoch - 101,
});

$txn->buy(skip_validation => 1);

# sell expired contract
BOM::Transaction::sell_expired_contracts({
    client => $test_client,
    source => 1,
});

# withdrawal
$test_client->payment_free_gift(
    currency => 'USD',
    amount   => -143,
    remark   => 'giving money out',
);

my ($advertiser, $advert);

#p2p
BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();
($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'buy');
$test_client->p2p_advertiser_create(name => 'bob');
my $order = BOM::Test::Helper::P2P::create_order(
    amount    => 50,
    advert_id => $advert->{id},
    client    => $test_client
);
$advertiser->p2p_order_cancel(id => $order->{id});

my $transaction_history = get_transaction_history($transac_param);

is scalar @$transaction_history, 7, 'there are 7 transactions';

# For this test case I'm defining what is expected, then compare with the result of get_transaction_history
my $expected = [{
        staff_loginid => 'AUTOSELL',
        source        => '1',
        action_type   => 'sell',
        referrer_type => 'financial_market_bet',
        amount        => '100.00',
        payout_price  => '100.00',
    },
    {
        staff_loginid => 'CR10000',
        source        => '19',
        action_type   => 'buy',
        referrer_type => 'financial_market_bet',
        payout_price  => '1000.00',
        amount        => '-514.00',
    },
    {
        staff_loginid => 'CR10000',
        action_type   => 'buy',
        referrer_type => 'financial_market_bet',
        payout_price  => '100.00',
        amount        => '-100.00',

    },
    {
        staff_loginid  => 'system',
        action_type    => 'withdrawal',
        referrer_type  => 'payment',
        amount         => '-143.00',
        payment_remark => 'giving money out',

    },
    {
        staff_loginid  => 'system',
        action_type    => 'deposit',
        referrer_type  => 'payment',
        payment_remark => 'free gift',
        amount         => '50000.00',
    },
    {
        staff_loginid => $test_client->loginid,
        action_type   => 'hold',
        referrer_type => 'p2p',
        amount        => '-50.00',
    },
    {
        staff_loginid => $advertiser->loginid,
        action_type   => 'release',
        referrer_type => 'p2p',
        amount        => '50.00',
    }];

my @expected_transactions = sort { 0 + $a->{amount} <=> 0 + $b->{amount} } @$expected;
my @got_transactions      = sort { 0 + $a->{amount} <=> 0 + $b->{amount} } @$transaction_history;

for my $idx (0 .. $#expected_transactions) {

    for my $col (keys %{$expected_transactions[$idx]}) {

        is $got_transactions[$idx]->{$col}, $expected_transactions[$idx]->{$col}, "$col matches for index $idx";
    }
}

my $default_account = Test::MockModule->new('BOM::User::Client');
$default_account->mock(
    'default_account',
    sub {
        return undef;
    });

$res = get_transaction_history($transac_param);
ok !$res, 'client does not have an account';

$default_account->unmock('default_account');

subtest 'transfer between accounts' => sub {
    my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'tba+1@binary.com'
    });
    $client_usd->account('USD');
    my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $client_usd->email
    });
    $client_btc->account('BTC');

    my $user = BOM::User->create(
        email    => $client_usd->email,
        password => 'test'
    );
    $user->add_client($client_usd);
    $user->add_client($client_btc);
    BOM::Test::Helper::Client::top_up($client_usd, $client_usd->currency, 1000);

    # setting of txn_details values is covered in bom-rpc/t/BOM/RPC/Cashier/20_transfer_between_accounts.t
    my $txn = $client_usd->payment_account_transfer(
        currency    => 'USD',
        amount      => 10,
        to_amount   => 1,
        toClient    => $client_btc,
        remark      => 'blabla',
        fees        => 1.1,
        txn_details => {
            from_login                => $client_usd->loginid,
            to_login                  => $client_btc->loginid,
            fees                      => 1.1,
            fees_currency             => 'USD',
            fees_percent              => 1.5,
            min_fee                   => 0.5,
            fee_calculated_by_percent => 1.1,
        },
    );

    my $res = get_transaction_history({
        client => $client_usd,
        args   => {action_type => 'transfer'},
    });

    is scalar(@$res), 1, 'Correct number of internal account transfers';

    my $expected = $res->[0];
    is $expected->{action_type},       'transfer',          'Correct action type';
    is $expected->{payment_type_code}, 'internal_transfer', 'Currect payment type code';

    ok exists $expected->{fees}, 'fees exists';
    ok exists $expected->{from}, 'from exists';
    ok exists $expected->{to},   'to exists';

    my $output = [{
            'action_type'   => 'transfer',
            'amount'        => '-10.00',
            'balance_after' => '990.00',
            'details'       => {
                'fee_calculated_by_percent' => '1.1',
                'fees'                      => '1.1',
                'fees_currency'             => 'USD',
                'fees_percent'              => '1.5',
                'from_login'                => 'CR10003',
                'min_fee'                   => '0.5',
                'to_login'                  => 'CR10004'
            },
            'fees' => {
                'amount'     => '1.10',
                'currency'   => 'USD',
                'minimum'    => '0.5',
                'percentage' => '1.5'
            },
            'from'                 => {'loginid' => 'CR10003'},
            'id'                   => $expected->{id},
            'payment_gateway_code' => 'account_transfer',
            'payment_id'           => '201979',
            'payment_remark'       => 'Account transfer to CR10004. Includes transfer fee of 1.10 USD (1.5%).',
            'payment_time'         => $expected->{payment_time},
            'payment_type_code'    => 'internal_transfer',
            'referrer_type'        => 'payment',
            'source'               => undef,
            'staff_loginid'        => 'system',
            'to'                   => {'loginid' => 'CR10004'},
            'transaction_time'     => $expected->{transaction_time},
        }];

    cmp_deeply($output, $res, 'Correct structure');
};

done_testing();
1;
