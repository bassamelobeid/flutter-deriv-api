package BOM::System::Host;

use Moose;
use namespace::autoclean;
use Moose::Util::TypeConstraints;
use MooseX::StrictConstructor;
use MooseX::Types::Moose qw( Int Str );
use BOM::System::Types qw( bom_ipv4_host_address );
use Sys::Hostname qw();

=head1 NAME

BOM::System::Host

=head1 SYNOPSYS

    my $server = BOM::System::Host->new(
        name           => 'cr-deal01',
        domain         => 'regentmarkets.com',
        groups         => [ 'rmg' ],
        roles          => [ BOM::System::Host::Role::Registry->get('customer_facing_webserver') ],
    );

=head1 DESCRIPTION

This class represents a single network host (which could be a server, a router, a printer, or anything).

=head1 ATTRIBUTES

=cut

=head2 name

name of the server. e.g. collector01

=cut

has name => (
    is       => 'ro',
    required => 1,
);

=head2 domain

The internal domain name. E.g. regentmarkets.com
This is used for machines to talk to each other,
the address listed here should not be published
to the internet.

This allows us to sit behind protective/cdn proxies
like cloudflare while still allowing our services to
communicate bypassing the proxies

=cut

has domain => (
    is      => 'ro',
    default => 'regentmarkets.com',
);

=head2 domain

Externally reachable domain name. E.g. binary.com
This is the address reachable from the internet

=cut

has external_domain => (
    is      => 'ro',
    default => 'binary.com',
);

=head2 groups
The group(s) to which this host belongs.

=cut

has groups => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { ['rmg'] },
);

=head2 roles

The role(s) played by this host.

=cut

has roles => (
    is      => 'rw',
    isa     => 'ArrayRef[BOM::System::Host::Role]',
    default => sub { [] },
);

has 'role_definitions' => (
    is  => 'ro',
    isa => 'Maybe[BOM::System::Host::Role::Registry]',
);

=head1 METHODS

=head2 $self->fqdn

Return full internal domain name for this server. E.g. collector01.regentmarkets.com
For difference between I<fqdn> and I<external_fqdn> check I<domain> and I<external_domain>

=cut

sub fqdn {
    my $self = shift;
    return $self->name . '.' . $self->domain;
}

=head2 $self->external_fqdn

Return full external domain name for this server. E.g. collector01.binary.com
For difference between I<fqdn> and I<external_fqdn> check I<domain> and I<external_domain>

=cut

sub external_fqdn {
    my $self = shift;
    return $self->name . '.' . $self->external_domain;
}

=head2 is_collector

Is this a collector (also known as Master Live Server)?

=cut

sub is_collector {
    my $self = shift;
    return $self->has_role('master_live_server') ? 1 : 0;
}

=head2 $self->has_role($role)

Returns true if $self->roles contains $role, undef otherwise. See C<BOM::System::Host::Role>.

=cut

sub has_role {
    my $self  = shift;
    my $role  = shift;
    my @roles = (grep { $_->has_role($role) } (@{$self->roles}));
    return @roles ? 1 : undef;    # Coding to the coverage tool here
}

=head2 BUILDARGS

As necessary, this method converts:

- 'localhost' name into the actual name of the local host
- named roles into BOM::System::Host::Role objects

=cut

sub BUILDARGS {
    my $self    = shift;
    my $arg_ref = shift;

    if ($arg_ref->{name} and $arg_ref->{name} eq 'localhost') {
        my @name = split(/\./, Sys::Hostname::hostname);
        $arg_ref->{name} = $name[0];
    }

    my $role_definitions = $arg_ref->{role_definitions};
    my $actual_roles     = [];
    if ($role_definitions) {
        foreach my $role (@{$arg_ref->{roles}}) {
            if (not ref $role) {
                my $obj = $role_definitions->get($role);
                if ($obj) {
                    push @$actual_roles, $obj;
                } else {
                    Carp::croak("Unknown BOM::System::Host::Role $role");
                }
            } else {
                push @$actual_roles, $role;
            }
        }
    }
    $arg_ref->{roles} = $actual_roles;

    return $arg_ref;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Nick Marden, C<< <nick at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut

