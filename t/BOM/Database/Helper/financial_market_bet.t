#!perl

use strict;
use warnings;
use Test::More;
use Test::Warnings;
use Test::Exception;

use BOM::Database::Helper::FinancialMarketBet;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Date::Utility;

my $clientdb = BOM::Database::ClientDB->new({
    broker_code => 'CR',
});

my $client1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $client3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $account1 = $client1->set_default_account('USD');
my $account2 = $client2->set_default_account('USD');
my $account3 = $client3->set_default_account('USD');

$client1->payment_free_gift(
    currency => 'USD',
    amount   => 500,
    remark   => 'free gift',
);
$client2->payment_free_gift(
    currency => 'USD',
    amount   => 500,
    remark   => 'free gift',
);
$client3->payment_free_gift(
    currency => 'USD',
    amount   => 500,
    remark   => 'free gift',
);

my %account_data1 = (
    account_data => {
        client_loginid => $account1->client_loginid,
        currency_code  => $account1->currency_code
    });
my %account_data2 = (
    account_data => {
        client_loginid => $account2->client_loginid,
        currency_code  => $account2->currency_code
    });
my %account_data3 = (
    account_data => {
        client_loginid => $account3->client_loginid,
        currency_code  => $account3->currency_code
    });

# batch buy bet, buy the same bet on multiple accounts
my $now        = Date::Utility->new;
my $short_code = ('CALL_R_50_200_' . $now->epoch . '_' . $now->plus_time_interval('15s')->epoch . '_S0P_0');
my $bet_data   = {
    underlying_symbol => 'frxUSDJPY',
    payout_price      => 200,
    buy_price         => 20,
    quantity          => 1,
    remark            => 'Test Remark',
    purchase_time     => $now->db_timestamp,
    start_time        => $now->db_timestamp,
    expiry_time       => $now->plus_time_interval('15s')->db_timestamp,
    settlement_time   => $now->plus_time_interval('15s')->db_timestamp,
    is_expired        => 1,
    is_sold           => 0,
    bet_class         => 'higher_lower_bet',
    bet_type          => 'CALL',
    short_code        => $short_code,
    relative_barrier  => 'S0P',
    quantity          => 1,
};

my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
    account_data => [$account_data1{account_data}, $account_data2{account_data}],
    bet_data     => $bet_data,
    db           => $clientdb->db,
});

my $result = $financial_market_bet_helper->batch_buy_bet;

my $acc     = $account1;
my $loginid = $acc->client_loginid;
subtest 'testing buy result for ' . $loginid, sub {
    my $r = shift @$result;
    isnt $r,                undef,    'got result hash';
    is $r->{loginid},       $loginid, 'found loginid';
    is $r->{e_code},        undef,    'e_code is undef';
    is $r->{e_description}, undef,    'e_description is undef';
    isnt $r->{fmb},         undef,    'got FMB';
    isnt $r->{txn},         undef,    'got TXN';

    my $fmb = $r->{fmb};
    is $fmb->{account_id}, $acc->id,    'fmb account id matches';
    is $fmb->{short_code}, $short_code, 'short code matches';

    my $txn = $r->{txn};
    is $txn->{account_id},              $acc->id,               'txn account id matches';
    is $txn->{referrer_type},           'financial_market_bet', 'txn referrer_type is financial_market_bet';
    is $txn->{financial_market_bet_id}, $fmb->{id},             'txn fmb id matches';
    is $txn->{amount},                  '-20.00',               'txn amount';
    is $txn->{balance_after},           '480.00',               'txn balance_after';
};

$acc     = $account2;
$loginid = $acc->client_loginid;
subtest 'testing buy result for ' . $loginid, sub {
    my $r = shift @$result;
    isnt $r,                undef,    'got result hash';
    is $r->{loginid},       $loginid, 'found loginid';
    is $r->{e_code},        undef,    'e_code is undef';
    is $r->{e_description}, undef,    'e_description is undef';
    isnt $r->{fmb},         undef,    'got FMB';
    isnt $r->{txn},         undef,    'got TXN';

    my $fmb = $r->{fmb};
    is $fmb->{account_id}, $acc->id,    'fmb account id matches';
    is $fmb->{short_code}, $short_code, 'short code matches';

    my $txn = $r->{txn};
    is $txn->{account_id},              $acc->id,               'txn account id matches';
    is $txn->{referrer_type},           'financial_market_bet', 'txn referrer_type is financial_market_bet';
    is $txn->{financial_market_bet_id}, $fmb->{id},             'txn fmb id matches';
    is $txn->{amount},                  '-20.00',               'txn amount';
    is $txn->{balance_after},           '480.00',               'txn balance_after';
};

# sell contracts by shortcode
$financial_market_bet_helper->bet_data->{sell_price} = 18;
$financial_market_bet_helper->bet_data->{quantity}   = 1;
$financial_market_bet_helper->bet_data->{sell_time}  = $now->plus_time_interval('1s')->db_timestamp;

$result = $financial_market_bet_helper->sell_by_shortcode($short_code);

$acc     = $account1;
$loginid = $acc->client_loginid;
subtest 'testing sell result for ' . $loginid, sub {
    is ref $result, 'ARRAY';
    my $r = shift @$result;
    is ref $r,          'HASH';
    isnt $r->{fmb},     undef, 'got FMB';
    isnt $r->{txn},     undef, 'got TXN';
    isnt $r->{loginid}, undef, 'got LOGINID';

    my $fmb = $r->{fmb};
    is $fmb->{account_id}, $acc->id,    'fmb account id matches';
    is $fmb->{short_code}, $short_code, 'short code matches';

    my $txn = $r->{txn};
    is $txn->{financial_market_bet_id}, $r->{fmb}{id}, 'txn fmb id matches';
    is $txn->{amount},                  '18.00',       'txn amount';
};

$acc     = $account2;
$loginid = $acc->client_loginid;
subtest 'testing sell result for ' . $loginid, sub {
    is ref $result, 'ARRAY';
    my $r = shift @$result;
    is ref $r,          'HASH';
    isnt $r->{fmb},     undef, 'got FMB';
    isnt $r->{txn},     undef, 'got TXN';
    isnt $r->{loginid}, undef, 'got LOGINID';

    my $fmb = $r->{fmb};
    is $fmb->{account_id}, $acc->id,    'fmb account id matches';
    is $fmb->{short_code}, $short_code, 'short code matches';

    my $txn = $r->{txn};
    is $txn->{financial_market_bet_id}, $r->{fmb}{id}, 'txn fmb id matches';
    is $txn->{amount},                  '18.00',       'txn amount';
};

# buy multiple bets on same account
$now        = Date::Utility->new;
$short_code = ('CALL_R_50_200_' . $now->epoch . '_' . $now->plus_time_interval('15s')->epoch . '_S0P_0');
$bet_data   = {
    underlying_symbol => 'frxUSDJPY',
    payout_price      => 200,
    buy_price         => 20,
    quantity          => 1,
    remark            => 'Test Remark',
    purchase_time     => $now->db_timestamp,
    start_time        => $now->db_timestamp,
    expiry_time       => $now->plus_time_interval('15s')->db_timestamp,
    settlement_time   => $now->plus_time_interval('15s')->db_timestamp,
    is_expired        => 1,
    is_sold           => 0,
    bet_class         => 'higher_lower_bet',
    bet_type          => 'CALL',
    short_code        => $short_code,
    relative_barrier  => 'S0P',
    quantity          => 1,
};

$financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
    %account_data3,
    bet_data => $bet_data,
    db       => $clientdb->db,
});

my @usd_bets;

cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$account3->client_loginid, 'USD', 'false'])},
    '==', 0, 'check qty of open bets before buying any bets');

# buy 1st bet
my ($fmb, $txn) = $financial_market_bet_helper->buy_bet;
push @usd_bets, $fmb->{id};

# buy 2nd bet
($fmb, $txn) = $financial_market_bet_helper->buy_bet;
push @usd_bets, $fmb->{id};

cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$account3->client_loginid, 'USD', 'false'])},
    '==', 2, 'check qty of open bets after buying 2 bets');

my @bets_to_sell =
    map { {id => $_, quantity => 1, sell_price => 30, sell_time => Date::Utility->new->plus_time_interval('1s')->db_timestamp,} } @usd_bets;
my @qvs = (
    BOM::Database::Model::DataCollection::QuantsBetVariables->new({
            data_object_params => {theo => 0.02},
        })) x @bets_to_sell;

$financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
    bet_data             => \@bets_to_sell,
    quants_bet_variables => \@qvs,
    %account_data3,
    db => $clientdb->db,
});

$financial_market_bet_helper->batch_sell_bet;
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$account3->client_loginid, 'USD', 'false'])},
    '==', 0, 'check qty of open bets after selling 2 bets');

done_testing;
