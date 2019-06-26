use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::FailWarnings;
use JSON::MaybeUTF8 qw(:v1);
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

my $t = build_wsapi_test();

my $req = {
    "mt5_password_check" => 1,
    "login"              => "1000",
    "password"           => "abc1234",
    "password_type"      => "main"
};

$t->send_ok({json => $req})->message_ok;
my $res = decode_json_utf8($t->message->[1]);
cmp_ok($res->{echo_req}{password}, 'eq', '<not shown>', 'password masked');
$req->{password} = ignore();
cmp_deeply($res->{echo_req}, $req, 'rest of echo_req matches request');

$t->finish_ok;

done_testing();
