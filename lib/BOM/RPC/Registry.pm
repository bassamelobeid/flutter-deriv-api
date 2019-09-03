package BOM::RPC::Registry;

use 5.014;
use strict;
use warnings;

use Carp;

use Sub::Util qw(set_subname);
use Scalar::Util qw(blessed);

use Struct::Dumb qw(readonly_struct);

readonly_struct
    ServiceDef        => [qw(name code category is_auth is_async)],
    named_constructor => 1;

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

=head2 async_rpc

    async_rpc $name => %opts..., sub {
        CODE... returning Future
    }

A shortcut for defining an RPC with the C<async> option set; i.e. one whose
results are returned asynchronously via a L<Future>.

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

    my $rpc_keyword = sub {
        my $code = pop;
        my $name = shift;
        my %opts = @_;

        $opts{auth} //= $auth_all if $auth_all;

        register($name, set_subname("RPC[$name]" => $code), %opts);

        # Install the new RPC function into the caller's symbol table
        no strict 'refs';
        *{"${caller}::$name"} = $code;

        return;
    };

    my %subs = (
        rpc => $rpc_keyword,

        async_rpc => sub {
            my $code = pop;
            $rpc_keyword->(
                @_,
                async => 1,
                $code
            );
        },

        requires_auth => sub {
            $auth_all = 1;
        },
    );

    # Install the new keywords as functions into the caller's symbol table
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

=item async => BOOL

Optional boolean. If true, the code is expected to return a L<Future>
instance, which will possibly-asynchronously resolve to the eventual result of
the RPC. If not, the code should return its result directly.

=back

=cut

my @service_defs;

my $done_startup = 0;

sub register {
    my ($name, $code, %args) = @_;

    Carp::croak "Too late to BOM::RPC::Registry::register" if $done_startup;

    push @service_defs,
        ServiceDef(
        name     => $name,
        code     => $code,
        category => $args{category} // 'default',
        is_auth  => !!$args{auth},
        is_async => !!$args{async},
        );
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

1;
