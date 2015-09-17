package BOM::Platform::Runtime::LandingCompany::Registry;

use namespace::autoclean;
use Moose;
use Carp;
use Try::Tiny;

use BOM::Platform::Runtime::LandingCompany;

with 'MooseX::Role::Registry';

=head1 METHODS

=head2 config_filename

The default location of the YML file describing known server roles.

=cut

sub config_file {
    return '/home/git/regentmarkets/bom-platform/config/landing_companies.yml';
}

=head2 build_registry_object

Builds I<BOM::Platform::Runtime::LandingCompany> object from definition.

=cut

sub build_registry_object {
    my $self   = shift;
    my $name   = shift;
    my $values = shift || {};
    return BOM::Platform::Runtime::LandingCompany->new({
        name => $name,
        %$values
    });
}

#Get by short or by name in that order, cause searching by short is much more common.
around 'get' => sub {
    my $orig = shift;
    my $self = shift;
    my $name = shift;

    return $self->_registry_by_short->{$name} || $self->$orig($name);
};

sub all_currencies {
    my $self       = shift;
    my $currencies = {};

    foreach my $lc ($self->all) {
        map { $currencies->{$_} = 1 } @{$lc->legal_allowed_currencies};
    }

    return keys %$currencies;
}

=head2 $self->get_landing_company(%spec)

return an array reference of L<BOM::Platform::Runtime::LandingCompany> objects for given parameter. I<%spec> may
contain any parameter by which it will search

=cut

sub get_landing_company {
    my ($self, %arg) = @_;

    my $result = [];

    if ($arg{short}) {
        push @{$result}, $self->_registry_by_short->{$arg{short}};
    } else {
        my $key = (keys %arg)[0];
        LANDING_COMPANIES:
        for my $lc (values %{$self->_registry}) {
            my $search;
            try { $search = $lc->$key; }
                or croak "Unable to search landing company by $key";
            if ($search eq $arg{$key}) {
                push @{$result}, $lc;
                last LANDING_COMPANIES;
            }
        }
    }

    return $result;
}

has _registry_by_short => (
    is  => 'rw',
    isa => 'HashRef[BOM::Platform::Runtime::LandingCompany]',
);

sub registry_fixup {
    my $self     = shift;
    my $registry = shift;

    my $registry_by_short = {};
    foreach my $lc (keys %$registry) {
        my $lc_obj = $registry->{$lc};
        my $short  = $lc_obj->short;
        if ($registry_by_short->{$lc_obj}) {
            Carp::croak("More than one BOM::Platform::Runtime::LandingCompany registered with short code"
                    . $short . ": "
                    . $lc_obj->name
                    . " conflicts with "
                    . $registry_by_short->{$short}->name);
        } else {
            $registry_by_short->{$short} = $lc_obj;
        }
    }

    $self->_registry_by_short($registry_by_short);

    return $registry;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut
