package BOM::Service::User;

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

    # This breaks the rule that the service will never throw errors, if you hit this you are
    # doing something very wrong, such code should never make it to prod.
    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to _dispatch_command not allowed outside of the BOM::Service namespace: " . caller() . "\n";
    }

    my $result;
    my $validation_passed = 0;

    try {
        if (my $command_struct = $command_map->{$request{command} // ''}) {
            # Quick check that the validation struct is defined, allow commands to use others validation, space saver
            my $validation_struct = exists $command_struct->{validation} ? $command_map->{$command_struct->{validation}} : $command_struct;
            die "Command validation not found for command '$request{command}'" unless defined $validation_struct;

            # Validate keys based on commands_list, whilst its not strictly necessary to validate the command
            # in this way the error messages are more readable. Filter out the required keys and validate.
            my @required_keys = sort grep { !$validation_struct->{parameters}{$_}{optional} } keys %{$validation_struct->{parameters}};
            my @missing_keys  = ();
            foreach my $required_key (@required_keys) {
                push @missing_keys, $required_key unless exists $request{$required_key};
            }
            die "Missing parameters: " . join(", ", @missing_keys) if scalar(@missing_keys) > 0;

            try {
                validate_with(
                    params      => \%request,
                    spec        => $validation_struct->{parameters},
                    allow_extra => 0,
                );
            } catch ($e) {
                die "Request parameter validation failed. $e";
            }

            # Validate user_id format (numeric or UUID)
            unless (looks_like_number($request{user_id})
                || $request{user_id} =~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/
                || $request{user_id} =~ /^.+@.+\..+$/)
            {
                die "The user_id must be numeric, valid UUID v4 or email";
            }

            # Validate context
            try {
                validate_with(
                    params => $request{context},
                    spec   => {
                        correlation_id => {type => SCALAR},
                        auth_token     => {type => SCALAR},
                        environment    => {type => SCALAR},
                    });
            } catch ($e) {
                die "Context validation failed. $e";
            }

            $validation_passed = 1;

            # Execute the command
            $result = $command_struct->{function}(\%request);
        } else {
            $result = {
                status  => 'error',
                class   => 'CommandNotFound',
                command => $request{command} // 'MISSING COMMAND - FIX ME!',
                message => 'Unknown command',
            };
        }
    } catch ($e) {
        my $message = $e;

        # Attempts to extract the error class and message from the exception
        my ($error_class, $human_readable_message) = split(/\|::\|/, $message, 2);

        # Check if splitting actually occurred
        if (!defined $human_readable_message) {
            # Splitting didn't occur, meaning the separator was not found
            $error_class            = 'GenericError';
            $human_readable_message = $message;
        }
        my $error = $human_readable_message;

        $human_readable_message =~ s/ in call to .+ at .+ line .+//s;
        $human_readable_message =~ s/ at .+\.pm line .+//s;
        $human_readable_message =~ s/\n\z//;

        # Has to be belt and braces here, we cannot guarantee that the request is a hashref
        my $command = $request{command} // 'MISSING COMMAND - FIX ME!';

        my @low_rank_errors = (qw(UserNotFound));
        if (grep { $_ eq $error_class } @low_rank_errors) {
            $log->info("Failure processing command '$command': $e");
        } else {
            $log->warn("Error processing command '$command': $e");
        }

        # Before we return we need to check if the cache needs to be flushed because updating
        # things is not an atomic event at the moment, there is a risk the cache object is
        # invalid i.e it has some unsaved values, we don't want to risk it being read back and
        # so cache should be flushed in the case of failed write operations
        if ($validation_passed && $command_map->{$request{command}}{cache_flush_on_error}) {
            BOM::Service::Helpers::flush_user_cache($request{user_id}, $request{context}{correlation_id});
            BOM::Service::Helpers::flush_client_cache($request{user_id}, $request{context}{correlation_id});
        }

        $result = {
            status  => 'error',
            class   => trim($error_class),
            message => trim($human_readable_message),
            command => $command,
        };

        # If we're not in prod also add the full error message
        $result->{error} = $error unless BOM::Config::on_production();
    };

    return $result;
}

1;
