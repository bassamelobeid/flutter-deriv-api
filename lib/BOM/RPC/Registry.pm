package BOM::RPC::Registry;

use 5.014;
use strict;
use warnings;

use Carp;

use Sub::Util qw(set_subname);
use Struct::Dumb qw(readonly_struct);

readonly_struct ServiceDef => [qw(name code before_actions)], named_constructor => 1;

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

=head2 common_before_actions

    common_before_actions $name, $name, ...

Sets a default list of action names, which will apply to subsequent uses of
the C<rpc> keyword in the same package. This list will be passed by default to
any RPC registration that does not otherwise specify a C<before_actions>. If
the C<rpc> keyword is passed a C<before_actions> then that list will entirely
override the common one - in particular it does not get merged.

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

    my @common_before_actions;

    my %subs = (
        rpc => sub {
            my $code = pop;
            my $name = shift;
            my %opts = @_;

            $opts{before_actions} //= \@common_before_actions if @common_before_actions;

            register($name, set_subname("RPC[$name]" => $code), %opts);

            no strict 'refs';
            *{"${caller}::$name"} = $code;

            return;
        },

        common_before_actions => sub {
            @common_before_actions = @_;
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

Takes the following additional named arguments:

=over 4

=item before_actions => ARRAY

Optional array reference containing prerequisite actions to be invoked before
the main code.

TODO(leonerd): discover this interface more and document it better

=back

=cut

my @service_defs;

my $done_startup = 0;

sub register {
    my ($name, $code, %args) = @_;

    Carp::croak "Too late to BOM::RPC::Registry::register" if $done_startup;

    push @service_defs, ServiceDef(
        name           => $name,
        code           => $code,
        before_actions => $args{before_actions},
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
