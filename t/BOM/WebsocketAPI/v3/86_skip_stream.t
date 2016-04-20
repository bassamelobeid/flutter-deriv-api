#!/usr/bin/perl

use strict;
use warnings;

use Test::Most;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;
use Test::MockModule;

use BOM::Platform::SessionCookie;
use BOM::System::RedisReplicated;

my $mocked = Test::MockModule->new('BOM::Product::Contract');
$mocked->mock('is_valid_to_buy', sub {1});

build_test_R_50_data();
my $t = build_mojo_test();

my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'sy@regentmarkets.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'sy@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR2002';

my $proposal_param = {
    "proposal"      => 1,
    "subscribe"     => 1,
    "amount"        => "10",
    "basis"         => "payout",
    "contract_type" => "PUT",
    "currency"      => "USD",
    "symbol"        => "R_50",
    "duration"      => "5",
    "duration_unit" => "h",
    "barrier"       => "+13.12"
};

note("non atm PUT");
$t = $t->send_ok({json => $proposal_param});
# proposal response
ok $t->message_ok, 'receive proposal';
my $res = decode_json($t->message->[1]);
ok $res->{proposal};
warn explain $res;

BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');
sleep 1;
$t = $t->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{proposal};
note explain $res;

$proposal_param->{contract_type} = 'ONETOUCH';
note("one touch");
$t = $t->send_ok({json => $proposal_param});
# proposal response
ok $t->message_ok, 'receive proposal';
$res = decode_json($t->message->[1]);
ok $res->{proposal};
note explain $res;

BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998049;443.6823;');
sleep 1;
$t = $t->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{proposal};
note explain $res;

$proposal_param->{contract_type} = 'RANGE';
$proposal_param->{barrier2} = '-13.12';
note("RANGE");
$t = $t->send_ok({json => $proposal_param});
# proposal response
ok $t->message_ok, 'receive proposal';
$res = decode_json($t->message->[1]);
ok $res->{proposal};
note explain $res;

BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998050;443.6823;');
sleep 1;
$t = $t->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{proposal};
note explain $res;

$proposal_param->{contract_type} = 'EXPIRYMISS';
$proposal_param->{barrier2} = '-13.12';
note("RANGE");
$t = $t->send_ok({json => $proposal_param});
# proposal response
ok $t->message_ok, 'receive proposal';
$res = decode_json($t->message->[1]);
ok $res->{proposal};
note explain $res;

BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998051;443.6823;');
sleep 1;
$t = $t->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{proposal};
note explain $res;

done_testing();
