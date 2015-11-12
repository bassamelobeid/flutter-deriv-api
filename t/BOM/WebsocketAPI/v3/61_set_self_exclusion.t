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
$res = decode_json($t->message->[1]);
ok($res->{get_self_exclusion});
test_schema('get_self_exclusion', $res);
diag Dumper(\$res);
is $res->{get_self_exclusion}->{max_balance},   '';
is $res->{get_self_exclusion}->{max_turnover},  '';
is $res->{get_self_exclusion}->{max_open_bets}, '', 'all are blank';

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
diag Dumper(\%data);
is $data{max_balance},   10000, 'max_balance saved ok';
is $data{max_turnover},  '',    'max_turnover is still blank';
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
my %data = %{$res->{get_self_exclusion}};
diag Dumper(\%data);
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
diag Dumper(\$res);
ok($res->{set_self_exclusion});
test_schema('set_self_exclusion', $res);

$t->finish_ok;

done_testing();
