package BOM::RPC::Registry;

use 5.014;
use strict;
use warnings;

use Carp;

use Sub::Util qw(set_subname);
use Scalar::Util qw(blessed);

=head1 DOMAIN-SPECIFIC-LANGUAGE

This module optionally provides some new keyword-like functions into its
caller, if imported with

    use BOM::RPC::Registry '-dsl';

These keywords are:

=head2 rpc

    rpc $name => %opts..., sub {
        CODE...
    }

A convenient way to define an RPC handling function by giving its name and an
anonymous function to implement it. The code reference is the final argument
to this keyword, for convenience and readability in the common case that the
function body is many lines long, allowing any named options to appear at the
start, lexically close to the C<rpc> keyword and method name.

The code reference will also be installed as a function of the same name in
the calling package. This is provided in order to support the prevailing style
of using named functions to implement RPC options, as code exists in various
places (such as unit tests) that expects to be able to invoke these directly.

=head2 requires_auth

    requires_auth();

Sets a default requirement of auth check, which will apply to subsequent uses of
the C<rpc> keyword in the same package. This list will be passed by default to
any RPC registration that does not otherwise specify a C<auth>.

=cut

sub import {
    my ($pkg, @syms) = @_;
    my $caller = caller;
    my %syms = map { $_ => 1 } @syms;

    if (delete $syms{"-dsl"}) {
        $pkg->import_dsl_into($caller);
    }

    keys %syms
        and Carp::croak "Unrecognised import symbols " . join(", ", keys %syms);

    return;
}

sub import_dsl_into {
    my ($pkg, $caller) = @_;

    my $auth_all;

    my %subs = (
        rpc => sub {
            my $code = pop;
            my $name = shift;
            my %opts = @_;

            $opts{auth} //= $auth_all if $auth_all;

            $code = do {
                my $original_code = $code;
                sub {
                    my $params = $_[0] // {};
                    my $client = $params->{client};

                    if (!$client) {
                        # If there is no $client, we continue with our auth check
                        my $err = _auth($params);
                        return $err if $err;
                    } else {
                        # If there is a $client object but is not a Valid Client::Account we return an error
                        unless (blessed $client && $client->isa('Client::Account')) {
                            return BOM::RPC::v3::Utility::create_error({
                                    code              => 'InvalidRequest',
                                    message_to_client => localize("Invalid request.")});
                        }
                    }

                    return $original_code->($params);
                    }
            } if $opts{auth};

            register($name, set_subname("RPC[$name]" => $code));

            no strict 'refs';
            *{"${caller}::$name"} = $code;

            return;
        },

        requires_auth => sub {
            $auth_all = 1;
        },
    );

    no strict 'refs';
    *{"${caller}::$_"} = $subs{$_} for keys %subs;

    return;
}

=head1 FUNCTIONS

=cut

=head2 register

    BOM::RPC::Registry::register( $name, $code, ... )

Adds a new named RPC to the list of services handled by the server.

This package method is intended to be called by modules C<use>d by the main
application.

TODO(leonerd): discover this interface more and document it better

=cut

my @service_defs;

my $done_startup = 0;

sub register {
    my ($name, $code) = @_;

    Carp::croak "Too late to BOM::RPC::Registry::register" if $done_startup;

    push @service_defs, [$name => $code];
    return;
}

=head2 get_service_defs

    @defs = get_service_defs()

Return the list of service definitions. For internal use by L<BOM::RPC>
directly.

=cut

sub get_service_defs {
    # It's now an error to add any more things to the @service_defs array;
    # it'll be too late
    $done_startup = 1;

    return @service_defs;
}

sub _auth {
    my $params = shift;

    my $token_details = $params->{token_details};
    return BOM::RPC::v3::Utility::invalid_token_error()
        unless $token_details and exists $token_details->{loginid};

    my $client = Client::Account->new({loginid => $token_details->{loginid}});

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }
    $params->{client} = $client;
    $params->{app_id} = $token_details->{app_id};
    return;
}

1;
