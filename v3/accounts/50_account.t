use strict;
use warnings;
use Test::More;

use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;
use Test::MockModule;

use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Transaction;
use BOM::MarketData qw(create_underlying_db);
use BOM::Database::Model::OAuth;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);

use BOM::User::Password;
use BOM::User;

use await;

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

# Mock exchange rates
populate_exchange_rates({
    USD => 1,
    EUR => 1.1888,
    GBP => 1.3333,
    JPY => 0.0089,
    BTC => 6000,
});

my $hash_pwd = BOM::User::Password::hashpw('jskjd8292922');
my $user     = BOM::User->create(
    email    => $test_client->email,
    password => $hash_pwd
);
$user->add_client($test_client);

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
        bet_type     => 'CALL',
        currency     => 'USD',
        stake        => 100,
        date_start   => $now->epoch - 100,
        date_expiry  => $now->epoch - 50,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        barrier      => 'S0P',
    });

    my $txn = BOM::Transaction->new({
        client        => $test_client,
        contract      => $contract_expired,
        price         => 100,
        payout        => $contract_expired->payout,
        amount_type   => 'stake',
        purchase_date => $now->epoch - 101,
    });

    $txn->buy(skip_validation => 1);

}

my $authorize = $t->await::authorize({authorize => $token});

is $authorize->{authorize}->{email},   'unit_test@binary.com';
is $authorize->{authorize}->{loginid}, $test_client->loginid;

my $statement = $t->await::statement({
    statement => 1,
    limit     => 5
});
ok($statement->{statement});
is($statement->{statement}->{count}, 5);
test_schema('statement', $statement);

subtest 'request_report' => sub {

    ## request_report
    my $request_report = $t->await::request_report({
        request_report => 1,
        report_type    => "statement",
        date_from      => 1534036304,
        date_to        => 1535036304,
    });
    ok($request_report->{request_report});
    is($request_report->{request_report}->{report_status}, 1);
    test_schema('request_report', $request_report);

};

subtest 'account_statistics' => sub {

    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => -15,
        remark   => 'not so free gift',
    );

    my $account_stats = $t->await::account_statistics({
        account_statistics => 1,
    });
    ok($account_stats->{account_statistics});
    is($account_stats->{account_statistics}->{total_deposits},    1000.00);
    is($account_stats->{account_statistics}->{total_withdrawals}, 15.00);
    is($account_stats->{account_statistics}->{currency},          'USD');
    test_schema('account_statistics', $account_stats);

};

subtest 'balance' => sub {
    my $res = $t->await::balance({balance => 1});
    ok $res->{balance};
    is $res->{balance}->{id}, undef, 'No id for non-subscribers';
    is $res->{subscription}, undef, 'Not subscription id';
    test_schema('balance', $res);

    $res = $t->await::balance({
        balance   => 1,
        subscribe => 0,
    });
    ok $res->{balance};
    is $res->{balance}->{id}, undef, 'No id for non-subscribers';
    is $res->{subscription}, undef, 'Not subscription id';
    test_schema('balance', $res);

    $res = $t->await::balance({
        balance   => 1,
        subscribe => 1,
    });

    ok $res->{balance};
    my $uuid = $res->{balance}->{id};
    ok $uuid, 'There is an id after subscription';
    is $res->{subscription}->{id}, $uuid, 'Subscription id with the same value';
    test_schema('balance', $res);

    $res = $t->await::balance({
        balance   => 1,
        subscribe => 1,
    });
    cmp_ok $res->{msg_type},, 'eq', 'balance';
    cmp_ok $res->{error}->{code}, 'eq', 'AlreadySubscribed', 'AlreadySubscribed error expected';

    my $data = $t->await::forget_all({forget_all => 'balance'});
    is(scalar @{$data->{forget_all}}, 1, 'Correct number of subscriptions');
    is $data->{forget_all}->[0], $uuid, 'Correct subscription id';
};

my $profit_table = $t->await::profit_table({
    profit_table => 1,
    limit        => 1
});
ok($profit_table->{profit_table});
ok($profit_table->{profit_table}->{count});
my $trx = $profit_table->{profit_table}->{transactions}->[0];
ok($trx);
ok($trx->{$_}, "got $_") foreach (qw/sell_price buy_price purchase_time contract_id transaction_id/);
test_schema('profit_table', $profit_table);

my (undef, $call_params) = call_mocked_client($t, {get_limits => 1});
is $call_params->{language}, 'EN';
ok exists $call_params->{token};

my $res = $t->await::get_limits({get_limits => 1});
ok($res->{get_limits});
is $res->{msg_type}, 'get_limits';
is $res->{get_limits}->{open_positions}, 100;
test_schema('get_limits', $res);

my $args = {
    "set_financial_assessment" => 1,
    %{BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash()}};
my $val = delete $args->{estimated_worth};
$res = $t->await::set_financial_assessment($args);
is($res->{error}->{code}, 'InputValidationFailed', 'Missing required field: estimated_worth');

$args->{estimated_worth} = $val;
$res = $t->await::set_financial_assessment($args);
is($res->{set_financial_assessment}->{total_score}, 8, "Total score for set ok");
note("set_financial_assessment json :: ");
note explain $res;

$res = $t->await::get_financial_assessment({get_financial_assessment => 1});
is($res->{get_financial_assessment}->{total_score}, 8, "Total score for get ok");

$t->finish_ok;

done_testing();
