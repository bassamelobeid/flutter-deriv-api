#!/usr/bin/env perl
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Time;

use Mojo::Server::Daemon;
use BOM::RPC::Transport::HTTP;
use BOM::Test::Helper::P2P;

=head1 name

bom_rpc_for_test.pl - The script to start bom-rpc service for testing

=head1 DESCRIPTION

This file is used to prepare a test environment and start bom-rpc service. It will be used by binary-websocket-api tests.

=head1 Environment Variables

=over 4

=item $ENV{RPC_URL}

The rpc URL that rpc service will listen to.

=back

=cut

my $rpc_url = $ENV{RPC_URL};
my $rpc     = BOM::RPC::Transport::HTTP->new();
my $daemon  = Mojo::Server::Daemon->new(
    app    => $rpc,
    listen => [$rpc_url],
);

# Mock WebService::SendBird
BOM::Test::Helper::P2P::bypass_sendbird();

local $SIG{HUP} = sub {
    $daemon->stop;
    exit;
};
$daemon->run;
