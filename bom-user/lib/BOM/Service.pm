package BOM::Service;

use strict;
use warnings;
no indirect;

use Text::Trim qw(trim);
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

use BOM::User;
use BOM::User::Client;
use BOM::Service::User::Attributes::Get;
use BOM::Service::User::Attributes::Update;
use BOM::Service::User::Status::LoginHistory;
use BOM::Service::Helpers;

=head1 NAME

BOM::Service - A module for dispatching user/wallet service command s within the BOM service framework.

=head1 SYNOPSIS

    use BOM::Service;

    # Dispatch a user command
    my $user_result = BOM::Service::user(command hash);

    # Dispatch a wallet command
    my $wallet_result = BOM::Service::wallet(command hash);

=head1 DESCRIPTION

This module provides functionality for dispatching commands to different parts of the BOM service
system, such as user and wallet services. It utilizes a command map for routing commands to the
appropriate handlers.

=cut

my %COMMAND_MAP = (
    user => {
        # ATTRIBUTES
        'get_attributes' => {
            function             => \&BOM::Service::User::Attributes::Get::get_attributes,
            cache_flush_on_error => 0,
            parameters           => {
                context    => {type => HASHREF},
                command    => {type => SCALAR},
                user_id    => {type => SCALAR},
                attributes => {
                    type      => ARRAYREF,
                    callbacks => {
                        'has one or more attributes requested' => sub {
                            my $array_ref = shift;
                            return scalar @$array_ref > 0;
                        },
                        'each item is a string' => sub {
                            my $array_ref = shift;
                            foreach my $item (@$array_ref) {
                                return 0 unless defined($item) && !ref($item) && $item =~ /^\s*[\w\s]+$/;
                            }
                            return 1;
                        }
                    },
                }
            },
        },
        'get_all_attributes' => {
            function             => \&BOM::Service::User::Attributes::Get::get_attributes,
            cache_flush_on_error => 0,
            parameters           => {
                context => {type => HASHREF},
                command => {type => SCALAR},
                user_id => {type => SCALAR},
            },
        },
        'update_attributes' => {
            function             => \&BOM::Service::User::Attributes::Update::update_attributes,
            cache_flush_on_error => 1,
            parameters           => {
                context => {type => HASHREF},
                command => {type => SCALAR},
                user_id => {type => SCALAR},
                flags   => {
                    type     => HASHREF,
                    optional => 1
                },
                attributes => {
                    type      => HASHREF,
                    callbacks => {
                        'has one or more attributes requested' => sub {
                            my $array_ref = [keys %{shift()}];
                            return scalar @$array_ref > 0;
                        },
                        'each key is a string' => sub {
                            my $array_ref = [keys %{shift()}];
                            foreach my $item (@$array_ref) {
                                return 0 unless defined($item) && !ref($item) && $item =~ /^\s*[\w\s]+$/;
                            }
                            return 1;
                        }
                    },
                }
            },
        },
        'update_attributes_nx' => {
            function   => \&BOM::Service::User::Attributes::Update::update_attributes_nx,
            validation => 'update_attributes',
        },
        'update_attributes_force' => {
            function   => \&BOM::Service::User::Attributes::Update::update_attributes_force,
            validation => 'update_attributes',
        },

        # Status
        'get_login_history' => {
            function             => \&BOM::Service::User::Status::LoginHistory::get_login_history,
            cache_flush_on_error => 0,
            parameters           => {
                context => {type => HASHREF},
                command => {type => SCALAR},
                user_id => {type => SCALAR},
                limit   => {
                    type    => SCALAR,
                    regex   => qr/^-?\d+$/,
                    message => "value must be an integer."
                },
                show_backoffice => {
                    type    => SCALAR,
                    regex   => qr/^[01]$/,
                    message => "value must be either 0 (false) or 1 (true)."
                }
            },
        },
        'add_login_history' => {
            function             => \&BOM::Service::User::Status::LoginHistory::add_login_history,
            cache_flush_on_error => 1,
            parameters           => {
                context     => {type => HASHREF},
                command     => {type => SCALAR},
                user_id     => {type => SCALAR},
                app_id      => {type => SCALAR},
                country     => {type => SCALAR},
                ip_address  => {type => SCALAR},
                environment => {type => SCALAR},
                error       => {type => SCALAR},
            },
        },
    },
    wallet => {},
);

=head2 user

    my $result = BOM::Service::user($request);

Executes a user-related command by dispatching it to the appropriate service handler within the user services command map. This method is a wrapper around the private `_dispatch_command` method, specifically setting up for user commands.

=over 4

=item * C<$command> (String) - The name of the command to execute.

=item * C<$user_id> (String/Number) - User identifier, numeric or string uuid/email

=item * C<$context> (Hashref) - Hash ref containing correlation id and access token.

Other parameters are command specific, see user service website API for details

=back

Returns a hash reference containing the command execution result.
=cut

sub user {
    return _dispatch_command($COMMAND_MAP{user}, @_);
}

=head2 user_email

Convenience call that uses the service to tell if there is a valid user available with the given
user_id also happens to return their email address

=cut

sub user_email {
    my ($context, $user_id) = @_;

    # If we can get a user response for that email its safe to proceed
    my $response = user({
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user_id,
        attributes => ['email'],
    });

    return $response->{attributes}{email};
}

=head2 get_user_id_from_client_id

Convenience call to get the user ID via a client id (loginid) its this or implement
service access by client and thats just backwards for the service, needed for
the backoffice at minimum.

THIS CALL IS TO SUPPORT A SINGLE USE CASE IN BACKOFFICE AND WILL BE REMOVED SOON, DO NOT USE IT!

=cut

sub get_user_id_from_client_id {
    my ($client_id) = @_;
    my $user = BOM::User->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("select * from users.get_user_by_loginid(?)", undef, $client_id);
        });
    if (defined $user) {
        return $user->{id};
    } else {
        return undef;
    }
}

=head2 wallet

    my $result = BOM::Service::wallet($command, $binary_user_id, $parameters, $correlation_id);

Executes a wallet-related command by dispatching it to the appropriate service handler within the wallet services command map. This method leverages the private `_dispatch_command` method, tailored for wallet commands.

=over 4

=item * C<$command> (String) - The name of the command to execute.

=item * C<$user_id> (String/Number) - User identifier, numeric or string uuid/email

=item * C<$context> (Hashref) - Hash ref containing correlation id and access token.

Other parameters are command specific, see user service website API for details

=back

Returns a hash reference containing the command execution result.
=cut

sub wallet {
    return _dispatch_command($COMMAND_MAP{wallet}, @_);
}

=head2 random_uuid

This subroutine generates a random UUID using the UUID::Tiny module. It specifically generates a UUID of version 4.

=over 4

=item * Input: None

=item * Return: String. A UUID v4 string.

=back

=cut

sub random_uuid {
    return UUID::Tiny::create_uuid_as_string(UUID::Tiny::UUID_V4);
}

# Everything below this line is private and should not be used outside of this module

=head2 _dispatch_command

A private method used internally to dispatch commands based on a provided command map. This method should not be called directly from outside the BOM::Service module.

    my $result = _dispatch_command($command_map, $request);

=over 4

=item * C<$command_map> (HashRef) - A reference to the command map specific to either user or wallet services.

=item * C<$request> (HashRef) - Request details.

=back

Executes the specified request if found in the command map; otherwise, returns an error. It also handles exceptions that may occur during command execution, logging the error and returning an error response.

Returns a hash reference containing the command execution result or error information.

=cut

sub _dispatch_command {
    my ($command_map, %request) = @_;

    # This breaks the rule that the service will never throw errors, if you hit this you are
    # doing something very wrong, such code should never make it to prod.
    unless (caller() =~ /^BOM::Service/) {
        die "Access denied!! Calls to BOM::Service::_dispatch_command not allowed outside of the BOM::Service namespace: " . caller() . "\n";
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
