use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::Client;
use Date::Utility;
use DateTime;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_mojo_test();

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_client->loginid,
    email   => $test_client->email,
)->token;

# authorize ok
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

# get_self_exclusion
$t = $t->send_ok({json => {get_self_exclusion => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
ok($res->{get_self_exclusion});
test_schema('get_self_exclusion', $res);
is_deeply $res->{get_self_exclusion}, {}, 'all are blank';

# set_self_exclusion
$t = $t->send_ok({
        json => {
            set_self_exclusion => 1,
            max_balance        => 10000,
            max_open_bets      => 100
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{set_self_exclusion});
test_schema('set_self_exclusion', $res);

# re-get should be get what saved
$t = $t->send_ok({json => {get_self_exclusion => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{get_self_exclusion});
test_schema('get_self_exclusion', $res);
my %data = %{$res->{get_self_exclusion}};
is $data{max_balance},   10000, 'max_balance saved ok';
is $data{max_turnover},  undef, 'max_turnover is not there';
is $data{max_open_bets}, 100,   'max_open_bets saved';

# plus save is ok
$t = $t->send_ok({
        json => {
            set_self_exclusion => 1,
            max_balance        => 9999,
            max_turnover       => 1000
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{set_self_exclusion});
test_schema('set_self_exclusion', $res);

# re-get should be get what saved
$t = $t->send_ok({json => {get_self_exclusion => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{get_self_exclusion});
test_schema('get_self_exclusion', $res);
%data = %{$res->{get_self_exclusion}};
is $data{max_balance},   9999, 'max_balance is updated';
is $data{max_turnover},  1000, 'max_turnover is saved';
is $data{max_open_bets}, 100,  'max_open_bets is untouched';

## do some validation
$t = $t->send_ok({
        json => {
            set_self_exclusion => 1,
            max_balance        => 10001,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'max_balance';
test_schema('set_self_exclusion', $res);

$t = $t->send_ok({
        json => {
            set_self_exclusion     => 1,
            max_balance            => 9999,
            session_duration_limit => 1440 * 42 + 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'session_duration_limit';
ok $res->{error}->{message} =~ /more than 6 weeks/;

$t = $t->send_ok({
        json => {
            set_self_exclusion     => 1,
            max_balance            => 9999,
            session_duration_limit => 1440,
            exclude_until          => '2010-01-01'
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'exclude_until';
ok $res->{error}->{message} =~ /after today/;

$t = $t->send_ok({
        json => {
            set_self_exclusion     => 1,
            max_balance            => 9999,
            session_duration_limit => 1440,
            exclude_until          => DateTime->now()->add(months => 3)->ymd
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'exclude_until';
ok $res->{error}->{message} =~ /less than 6 months/;

$t = $t->send_ok({
        json => {
            set_self_exclusion     => 1,
            max_balance            => 9999,
            session_duration_limit => 1440,
            exclude_until          => DateTime->now()->add(years => 6)->ymd
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'exclude_until';
ok $res->{error}->{message} =~ /more than five years/;

# good one
my $exclude_until = DateTime->now()->add(months => 7)->ymd;
$t = $t->send_ok({
        json => {
            set_self_exclusion     => 1,
            max_balance            => 9998,
            session_duration_limit => 1440,
            exclude_until          => $exclude_until
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{set_self_exclusion});
test_schema('set_self_exclusion', $res);

# re-get should be get what saved
$t = $t->send_ok({json => {get_self_exclusion => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{get_self_exclusion});
test_schema('get_self_exclusion', $res);
%data = %{$res->{get_self_exclusion}};
is $data{max_balance},            9998, 'max_balance is updated';
is $data{max_turnover},           1000, 'max_turnover is untouched';
is $data{session_duration_limit}, 1440, 'session_duration_limit is good';
is $data{exclude_until}, $exclude_until, 'exclude_until is good';

$t->finish_ok;

done_testing();
