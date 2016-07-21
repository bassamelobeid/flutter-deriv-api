use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::Client;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_mojo_test();

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

# test account status
my $reason = "test to set unwelcome login";
my $clerk  = 'shuwnyuan';
$test_client->set_status('unwelcome', $clerk, $reason);
$test_client->save();

# authorize ok
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

$t = $t->send_ok({json => {get_account_status => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
ok((grep { $_ eq 'unwelcome' } @{$res->{get_account_status}->{status}}), 'unwelcome is there');
test_schema('get_account_status', $res);

$t = $t->send_ok({json => {get_settings => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{get_settings});
my %old_data = %{$res->{get_settings}};
ok $old_data{address_line_1};
test_schema('get_settings', $res);

## set settings
my %new_data = (
    "address_line_1"   => "Test Address Line 1",
    "address_line_2"   => "Test Address Line 2",
    "address_city"     => "Test City",
    "address_state"    => "01",
    "address_postcode" => "123456",
    "phone"            => "1234567890"
);
$t = $t->send_ok({
        json => {
            set_settings => 1,
            %new_data
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{set_settings});    # update OK
test_schema('set_settings', $res);

## get settings and it should be updated
$t = $t->send_ok({json => {get_settings => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{get_settings});
my %now_data = %{$res->{get_settings}};
foreach my $f (keys %new_data) {
    is $now_data{$f}, $new_data{$f}, "$f is updated";
}
test_schema('get_settings', $res);

## test virtual
my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client_vr->loginid);

# authorize ok
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

$t = $t->send_ok({json => {get_settings => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{get_settings});
ok $res->{get_settings}->{email};
ok not $res->{get_settings}->{address_line_1};    # do not have address for virtual
test_schema('get_settings', $res);

# it should throw error b/c virtual can NOT update
$t = $t->send_ok({
        json => {
            set_settings => 1,
            %new_data
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'PermissionDenied';

## VR with no residence, try set residence = 'jp' should fail
$test_client_vr->residence('');
$test_client_vr->save;

$t = $t->send_ok({
        json => {
            set_settings => 1,
            residence    => 'jp',
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'PermissionDenied';

## JP client update setting should fail
my $client_jp = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'JP',
});
$client_jp->residence('jp');

$client_jp->financial_assessment({
    data =>
        '{"hedge_asset_amount":null,"jp_knowledge_test":[{"epoch":1467604241,"status":"pass","score":"20"}],"agreement":{"confirm_understand_total_loss":"2016-07-04 03:46:39","confirm_understand_judgment_time":"2016-07-04 03:46:39","confirm_understand_sellback_loss":"2016-07-04 03:46:39","confirm_understand_trading_mechanism":"2016-07-04 03:46:39","agree_warnings_and_policies":"2016-07-04 03:46:39","confirm_understand_own_judgment":"2016-07-04 03:46:39","confirm_understand_company_profit":"2016-07-04 03:46:39","confirm_understand_shortsell_loss":"2016-07-04 03:46:39","declare_not_fatca":"2016-07-04 03:46:39","confirm_understand_expert_knowledge":"2016-07-04 03:46:39","agree_use_electronic_doc":"2016-07-04 03:46:39"},"annual_income":{"answer":"Less than 1 million JPY","score":1},"trading_experience_equities":{"answer":"6 months to 1 year","score":3},"trading_experience_score":14,"trading_experience_public_bond":{"answer":"No experience","score":1},"hedge_asset":null,"trading_experience_investment_trust":{"answer":"No experience","score":1},"trading_experience_option_trading":{"answer":"No experience","score":1},"income_asset_score":3,"total_score":17,"trading_purpose":"Targeting medium-term / long-term profits","financial_asset":{"answer":"1-3 million JPY","score":2},"trading_experience_commodities":{"answer":"6 months to 1 year","score":3},"trading_experience_margin_fx":{"answer":"Less than 6 months","score":2},"trading_experience_foreign_currency_deposit":{"answer":"6 months to 1 year","score":3}}'
});

$client_jp->save;

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_jp->loginid);

# authorize ok
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

$t = $t->send_ok({
        json => {
            "set_settings" => 1,
            "jp_settings"  => {
                occupation                                  => 'Director',
                annual_income                               => 'Less than 1 million JPY',
                financial_asset                             => '1-3 million JPY',
                trading_experience_equities                 => '6 months to 1 year',
                trading_experience_commodities              => '6 months to 1 year',
                trading_experience_foreign_currency_deposit => '6 months to 1 year',
                trading_experience_margin_fx                => 'Less than 6 months',
                trading_experience_investment_trust         => 'No experience',
                trading_experience_public_bond              => 'No experience',
                trading_experience_option_trading           => 'No experience',
                trading_purpose                             => 'Hedging',
                hedge_asset                                 => 'Foreign currency deposit',
                hedge_asset_amount                          => '99999'
            }}})->message_ok;

$res = decode_json($t->message->[1]);

ok($res->{set_settings});    # update OK
test_schema('set_settings', $res);

$t->finish_ok;
done_testing();
