package BOM::Event::Actions::External;

use strict;
use warnings;

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

1;
