use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test;
use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = build_mojo_test();

my $token = BOM::Platform::SessionCookie->new(
    loginid => "CR0021",
    email   => 'shuwnyuan@regentmarkets.com',
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'shuwnyuan@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR0021';

$t = $t->send_ok({
        json => {
            statement => 1,
            limit     => 54
        }})->message_ok;
my $statement = decode_json($t->message->[1]);
ok($statement->{statement});
is($statement->{statement}->{count}, 54);
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

$t = $t->send_ok({json => {get_limits => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
ok($res->{get_limits});
is $res->{get_limits}->{open_positions}, 60;
test_schema('get_limits', $res);

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
    "net_income"                           => '$25,000 - $100,000'
};

$t = $t->send_ok({json => $args})->message_ok;
$res = decode_json($t->message->[1]);
is($res->{error}->{code}, 'InputValidationFailed', 'Missing required field: estimated_worth');

$args->{estimated_worth} = '$100,000 - $250,000';
$t = $t->send_ok({json => $args})->message_ok;
$res = decode_json($t->message->[1]);
cmp_ok($res->{set_financial_assessment}->{score}, "<", 60, "Correct score");
is($res->{set_financial_assessment}->{is_professional}, 0, "Marked correctly as is_professional");

$t->finish_ok;

done_testing();
