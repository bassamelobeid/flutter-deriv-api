#!/usr/bin/env perl
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Time;
use BOM::Config::Redis;

use BOM::RPC::Transport::Redis;
use BOM::Test::Helper::P2P;

=head1 NAME

binary_rpc_redis_for_test.pl - Will start a C<BOM::RPC::Transport::Redis> for testing

=head1 DESCRIPTION

This script is used to prepare a test environment and create and start a C<BOM::RPC::Transport::Redis> instance. It will be used by binary-websocket-api tests.

=cut

# Mock WebService::SendBird
BOM::Test::Helper::P2P::bypass_sendbird();

my $redis_cfg = BOM::Config::Redis::redis_config('rpc', 'write');
my $consumer = BOM::RPC::Transport::Redis->new(
    worker_index => 1,
    redis_uri    => $redis_cfg->{uri},
);

local $SIG{HUP} = sub {
    $consumer->stop;
    exit;
};

$consumer->run();
