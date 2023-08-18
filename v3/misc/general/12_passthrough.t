use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::FailWarnings;
use JSON::MaybeUTF8   qw(:v1);
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

my $t = build_wsapi_test();

my $req = {
    "contracts_for"   => "R_50",
    "currency"        => "USD",
    "landing_company" => "svg",
    "product_type"    => "basic"
};

my $passthrough = {"key1" => "value1"};
$req->{passthrough} = $passthrough;

$t->send_ok({json => $req})->message_ok;

my $res = decode_json_utf8($t->message->[1]);
cmp_deeply($res->{passthrough}, $passthrough, 'Passthrough ok');

my $value_499_chars = "a" x 499;
$passthrough = {
    "key1" => [
        $value_499_chars, $value_499_chars, $value_499_chars, $value_499_chars, $value_499_chars,
        $value_499_chars, $value_499_chars, $value_499_chars, $value_499_chars
    ]};
$req->{passthrough} = $passthrough;

$t->send_ok({json => $req})->message_ok;
$res = decode_json_utf8($t->message->[1]);
cmp_deeply($res->{error}->{message}, 'Input validation failed: passthrough', 'Passthrough failed');

$t->finish_ok;

done_testing();
