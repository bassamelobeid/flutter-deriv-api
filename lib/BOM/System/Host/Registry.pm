package BOM::System::Host::Registry;

## no critic (RequireArgUnpacking,RequireLocalizedPunctuationVars)

=head1 NAME

BOM::System::Host::Role::Registry

=head1 SYNOPSYS

    my $registry = BOM::System::Host::Registry->new();
    my $host = $registry->get('collector01'); # By name
    my $host = $registry->get('tierpoint-collector01'); # By canonical name

=head1 DESCRIPTION

This class parses a file describing server roles and provides a singleton
lookup object to access this information. This is a singleton, you shouldn't
call I<new>, just get the object using I<instance> method.

=cut

use namespace::autoclean;
use Moose;
use Carp;

use BOM::System::Host;
use BOM::System::Host::Role::Registry;
use Sys::Hostname;
use List::Util qw( first shuffle );

with 'MooseX::Role::Registry';

has 'localhost' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'role_definitions' => (
    is  => 'ro',
    isa => 'BOM::System::Host::Role::Registry',
);

has '_registry_by_canonical_name' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

=head1 METHODS

=head2 config_filename

The default location of the YML file describing known server roles.

=cut

sub config_file {
    return '/etc/rmg/hosts.yml';
}

=head2 build_registry_object

All entries in the YML file are expected to be BOM::System::Host

=cut

sub build_registry_object {
    my $self   = shift;
    my $name   = shift;
    my $values = shift || {};

    return BOM::System::Host->new({
        name             => $name,
        role_definitions => $self->role_definitions,
        %$values
    });
}

around 'get' => sub {
    my $orig = shift;
    my $self = shift;
    my $name = shift;

    return $self->$orig($name) || $self->_registry_by_canonical_name->{$name};
};

=head2 registry_fixup

Builds the lookup hash by canonical name, but does not other affect the input registry hashref.

=cut

sub registry_fixup {
    my $self = shift;
    my $reg  = shift;

    my $_registry_by_canonical_name = {};
    foreach my $host (keys %$reg) {
        my $h  = $reg->{$host};
        my $cn = $h->canonical_name;
        if ($_registry_by_canonical_name->{$cn}) {
            Carp::croak("More than one BOM::System::Host registered with canonical name "
                    . $cn . ": "
                    . $h->name
                    . " conflicts with "
                    . $_registry_by_canonical_name->{$cn}->name);
        } else {
            $_registry_by_canonical_name->{$cn} = $h;
        }
        if ($h->virtualization_host and not ref $h->virtualization_host) {
            my $vh = first { $reg->{$_}->canonical_name eq $h->virtualization_host } (keys %$reg);
            if ($vh) {
                $h->virtualization_host($reg->{$vh});
            } else {
                Carp::croak("Unknown BOM::System::Host " . $h->virtualization_host . " given as virtualization host for $host");
            }
        }
    }

    $self->_registry_by_canonical_name($_registry_by_canonical_name);
    $reg->{localhost} = $self->_configure_localhost($reg);

    return $reg;
}

sub _configure_localhost {
    my $self = shift;
    my $reg  = shift;

    my $localhost = $reg->{localhost};
    unless ($localhost) {
        my $hostname = $self->_hostname;
        $localhost = $reg->{$hostname};
    }

#If we are not able to find localhost from config then we just add an default localhost.
    unless ($localhost) {
        $localhost = BOM::System::Host->new({
            name             => 'localhost',
            canonical_name   => 'localhost',
            ip_address       => '127.0.0.1',
            groups           => ['rmg'],
            role_definitions => $self->role_definitions,
            roles            => ['couchdb_master', 'couchdb_server'],
        });
    }

    return $localhost;
}

=head2 find_by_role($role[, $role, ...])

Returns an array of all BOM::System::Host objects stored in $self which have role $role.

Call with multiple $role values and the results will be de-duplicated (one host with two or more
of the specified roles will only be returned once).

=cut

sub find_by_role {
    my $self = shift;
    Carp::croak("Usage: find_by_role(role1[,...])") unless (@_);

    my $result = {};
    while (my $role = shift) {
        foreach my $server (grep { $_->has_role($role) } ($self->all)) {
            $result->{$server->canonical_name} = $server;
        }
    }
    return values %$result;
}

sub _build_localhost {
    my $self = shift;
    return $self->get('localhost');
}

sub _hostname {
    my $self     = shift;
    my $hostname = lc hostname;
    $hostname =~ s/^([^.]+).*$/$1/;
    return $hostname;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Nick Marden, C<< <nick at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut

