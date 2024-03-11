package BOM::Event::Actions::External;

use strict;
use warnings;

use BOM::Platform::Event::Emitter;
use BOM::Platform::Utility;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::Event::Actions::Client::IdentityVerification;

no indirect;

=head1 NAME

BOM::Event::Actions::External - messages that came from external services

=head1 DESCRIPTION

Provide handlers for messages received from external services.

=cut

use Log::Any qw($log);

=head2 nodejs_hello

Handler for the `nodejs_hello` diagnostic event.

Prints out a log message.

=cut

sub nodejs_hello {
    $log->info('Hello from nodejs');
}

=head2 send_idv_configuration

Handler for the `send_idv_configuration` event.

Calls IdentityVerification::send_idv_configuration sub and sends a DD metric.

=over 4

=item * C<provider> - the provider that should be disabled.

=item * C<ttl> - specified expire time of the redis key.

=back

=cut

async sub send_idv_configuration {
    await BOM::Event::Actions::Client::IdentityVerification::send_idv_configuration();
}

=head2 idv_configuration_disable_provider

Handler for the `idv_configuration_disable_provider` event.

Calls IdentityVerification::disable_provider and sends a DD metric.

=cut

async sub idv_configuration_disable_provider {
    my $args = shift;
    await BOM::Event::Actions::Client::IdentityVerification::disable_provider($args);
}

=head2 idv_configuration_enable_provider

Handler for the `idv_configuration_enable_provider` event.

Calls IdentityVerification::enable_provider and sends a DD metric.

=cut

async sub idv_configuration_enable_provider {
    my $args = shift;
    await BOM::Event::Actions::Client::IdentityVerification::enable_provider($args);
}

1;
