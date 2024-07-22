package BOM::Service::Wallet;

use strict;
use warnings;
no indirect;

use Text::Trim qw(trim);
use Storable   qw(dclone);
use Syntax::Keyword::Try;
use Date::Utility;
use Params::Validate      qw(:all);
use Format::Util::Numbers qw(formatnumber);
use List::Util            qw(first any all minstr uniq);
use Scalar::Util          qw(blessed looks_like_number);
use Carp                  qw(croak carp);
use Log::Any              qw($log);
use JSON::MaybeXS         qw(encode_json decode_json);
use UUID::Tiny;

=head2 dispatch_command

A private method used internally to dispatch user service commands based on a provided command map. This method should not be called directly from outside the BOM::Service module.

    my $result = dispatch_command($command_map, $request);

=over 4

=item * C<$command_map> (HashRef) - A reference to the command map specific to either user or wallet services.

=item * C<$request> (HashRef) - Request details.

=back

Executes the specified request if found in the command map; otherwise, returns an error. It also handles exceptions that may occur during command execution, logging the error and returning an error response.

Returns a hash reference containing the command execution result or error information.

=cut

sub dispatch_command {
    my ($command_map, %request) = @_;

    my $command = $request{command} // 'MISSING COMMAND - FIX ME!';

    my $result = {
        status  => 'error',
        class   => 'GenericWalletError',
        message => 'This service has not been implemented yed',
        command => $command,
    };

    return $result;
}

1;
