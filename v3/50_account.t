use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::Transaction;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

my $t = build_wsapi_test({language => 'EN'});

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

$test_client->payment_free_gift(
    currency => 'USD',
    amount   => 1000,
    remark   => 'free gift',
);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => $_,
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]}) for [qw(USD JPY)];

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

for (1 .. 10) {
    my $contract_expired = produce_contract({
        underlying   => $underlying,
        bet_type     => 'FLASHU',
        currency     => 'USD',
        stake        => 100,
        date_start   => $now->epoch - 100,
        date_expiry  => $now->epoch - 50,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        barrier      => 'S0P',
    });

    my $txn = BOM::Product::Transaction->new({
        client        => $test_client,
        contract      => $contract_expired,
        price         => 100,
        payout        => $contract_expired->payout,
        amount_type   => 'stake',
        purchase_date => $now->epoch - 101,
    });

    $txn->buy(skip_validation => 1);

}

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'unit_test@binary.com';
is $authorize->{authorize}->{loginid}, $test_client->loginid;

$t = $t->send_ok({
        json => {
            statement => 1,
            limit     => 5
        }})->message_ok;
my $statement = decode_json($t->message->[1]);
ok($statement->{statement});
is($statement->{statement}->{count}, 5);
test_schema('statement', $statement);

## balance
$t = $t->send_ok({json => {balance => 1}})->message_ok;
my $balance = decode_json($t->message->[1]);
ok($balance->{balance});
test_schema('balance', $balance);
# diag Dumper(\$balance);

$t = $t->send_ok({
        json => {
            profit_table => 1,
            limit        => 1,
        }})->message_ok;
my $profit_table = decode_json($t->message->[1]);
ok($profit_table->{profit_table});
ok($profit_table->{profit_table}->{count});
my $trx = $profit_table->{profit_table}->{transactions}->[0];
ok($trx);
ok($trx->{$_}, "got $_") foreach (qw/sell_price buy_price purchase_time contract_id transaction_id/);
test_schema('profit_table', $profit_table);

my (undef, $call_params) = call_mocked_client($t, {get_limits => 1});
is $call_params->{language}, 'EN';
ok exists $call_params->{token};

$t = $t->send_ok({json => {get_limits => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
ok($res->{get_limits});
is $res->{msg_type}, 'get_limits';
is $res->{get_limits}->{open_positions}, 60;
test_schema('get_limits', $res);

my $args = {
    "set_financial_assessment"             => 1,
    "account_opening_reason"               => "Speculative",
    "account_turnover"                     => 'Less than $25,000',
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
    "occupation"                           => 'Managers'
};

$t = $t->send_ok({json => $args})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{error}->{code}, 'InputValidationFailed', 'Missing required field: estimated_worth');

$args->{estimated_worth} = '$100,000 - $250,000';
$t = $t->send_ok({json => $args})->message_ok;
$res = decode_json($t->message->[1]);
cmp_ok($res->{set_financial_assessment}->{score}, "<", 60, "Correct score");
is($res->{set_financial_assessment}->{is_professional}, 0, "is_professional flag is set correctly");

$t->finish_ok;

done_testing();
