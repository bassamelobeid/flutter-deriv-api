#!/etc/rmg/bin/perl -I ../../../lib

use strict;
use warnings;

use Test::More (tests => 2);
use Test::Warnings;

use BOM::Platform::Context::Request;

subtest 'login_env' => sub {
    my $request = BOM::Platform::Context::Request->new();

    my ($actual, $expected);

    # Check with default request
    $actual   = $request->login_env();
    $expected = qr/IP=127.0.0.1 IP_COUNTRY=AQ User_AGENT= LANG=EN/;

    like($actual, $expected, 'login_env returns expected value.');

    # Check with parameters to overwrite
    my $params = {
        client_ip    => '1.1.1.1',
        country_code => 'TR',
        language     => 'en',
        user_agent   => 'ua'
    };

    $actual   = $request->login_env($params);
    $expected = qr/IP=1.1.1.1 IP_COUNTRY=TR User_AGENT=ua LANG=EN/;

    like($actual, $expected, 'login_env returns expected value.');

    my $agent_warning = 'AGENT_TRUNCATED';
    unlike($actual, qr/$agent_warning/, "login_env does not set $agent_warning for a normal length user_agent string");

    $params->{user_agent} = '1234567890' x 200;
    $actual = $request->login_env($params);
    like($actual, qr/$agent_warning=2000/, "login_env sets $agent_warning for an extra long user_agent string");
    is(length($actual), 1000, 'login_env returns a sane length string when user_agent is extra long');

};

done_testing();
