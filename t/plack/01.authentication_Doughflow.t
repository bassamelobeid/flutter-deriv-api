use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use Digest::MD5;
use APIHelper qw(request);

my $loginid = 'CR0011';

my $res = request('GET', '/ping');
ok($res->is_success, 'ping request should succeed');

sub get_request {
    my $now    = shift || time;
    my $secret = shift || 'N73X49dS6SmX9Tf4';
    my $hash   = substr(Digest::MD5::md5_hex("${now}${secret}"), -10);
    request("GET", "/account?client_loginid=$loginid&currency_code=USD", 0, {"X-BOM-DoughFlow-Authorization" => "$now:$hash"});
}

my $r = get_request();
ok($r->is_success, 'Doughflow authentication with valid credentials.');
like($r->content, qr/"client_loginid":"$loginid"/, '.. response includes correct client details');

$r = get_request(time - 15);
ok($r->is_success, 'Doughflow authentication with valid credentials (15 secs old).');
like($r->content, qr/"client_loginid":"$loginid"/, '.. response includes correct client details');

$r = get_request(time - 16);
ok($r->is_success, 'Doughflow authentication with 16 secs old timestamp');
like($r->content, qr/"client_loginid":"$loginid"/, '.. response includes correct client details');

$r = get_request(time - 60);
ok($r->is_success, 'Doughflow authentication with 60 secs old timestamp');
like($r->content, qr/"client_loginid":"$loginid"/, '.. response includes correct client details');

$r = get_request(time - 61);
ok(!$r->is_success, 'Doughflow authentication more than 60 secs old timestamp fails');
like($r->header('www-authenticate'), qr/Basic realm=/, '.. and requests for authentication');

$r = get_request(time, 'wrong-secret');
ok(!$r->is_success, 'Doughflow authentication w/ wrong credentials fail');
like($r->header('www-authenticate'), qr/Basic realm=/, '.. and requests for authentication');

done_testing();
