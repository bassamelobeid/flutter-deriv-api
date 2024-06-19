package BOM::Event::Script::NodeJSBridgeTest;

=head1 NAME

BOM::Event::Script::NodeJSBridgeTest

=head1 DESCRIPTION

Sends a message to the nodejs bridge

=cut

use strict;
use warnings;

use BOM::Platform::Event::Emitter;
use Future::AsyncAwait;
use IO::Async::Loop;

=head2 run

=cut

async sub run {
    BOM::Platform::Event::Emitter::emit('monolith_hello', 'Hello from perl monolith!');
}

1;
