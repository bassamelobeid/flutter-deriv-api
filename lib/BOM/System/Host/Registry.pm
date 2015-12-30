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

    return $self->$orig($name);
};

sub registry_fixup {
    my $self = shift;
    my $reg  = shift;

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
            role_definitions => $self->role_definitions,
            roles            => ['couchdb_master', 'couchdb_server'],
        });
    }

    return $localhost;
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

