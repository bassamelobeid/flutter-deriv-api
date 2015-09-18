package BOM::System::Host::Role::Registry;

=head1 NAME

BOM::System::Host::Role::Registry

=head1 SYNOPSYS

    my $registry = BOM::System::Host::Role::Registry->instance;
    my $role     = $registry->get('streamer');

=head1 DESCRIPTION

This class parses a file describing server roles and provides a singleton
lookup object to access this information. This is a singleton, you shouldn't
call I<new>, just get the object using I<instance> method.

=cut

use namespace::autoclean;
use Moose;

use BOM::System::Host::Role;
use Carp;

with 'MooseX::Role::Registry';

=head1 METHODS

=head2 config_filename

The default location of the YML file describing known server roles.

=cut

sub config_file {
    return '/home/git/regentmarkets/bom-platform/config/roles.yml';
}

=head2 build_registry_object

Builds I<BOM::System::Host::Role> object from the definition.

=cut

sub build_registry_object {
    my $self   = shift;
    my $name   = shift;
    my $values = shift || {};

    return BOM::System::Host::Role->new({
        name => $name,
        %$values
    });
}

=head2 registry_fixup

Where necessary, turns scalar names of inherited roles into BOM::System::Host::Role objects

=cut

sub registry_fixup {
    my $self = shift;
    my $reg  = shift;

    foreach my $role (keys %$reg) {
        my $new_inherits = [];
        foreach my $i (@{$reg->{$role}->inherits}) {
            if (ref $i) {
                push @$new_inherits, $i;
            } else {
                my $r = $reg->{$i};
                if ($r) {
                    push @$new_inherits, $r;
                } else {
                    Carp::croak("Role $role inherits from unknown role $i");
                }
            }
        }
        $reg->{$role}->inherits($new_inherits);
    }

    return $reg;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Nick Marden, C<< <nick at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut

