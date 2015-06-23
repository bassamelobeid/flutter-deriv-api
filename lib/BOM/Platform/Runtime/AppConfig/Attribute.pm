package BOM::Platform::Runtime::AppConfig::Attribute;

use Moose;
extends 'BOM::Platform::Runtime::AppConfig::Node';
use namespace::autoclean;
use JSON::XS qw( decode_json );
use Carp;

use MooseX::Types -declare => ['LongStr'];
use Moose::Util::TypeConstraints;
use Try::Tiny;

subtype 'LongStr', as 'Str';

=head1 NAME

BOM::Platform::Runtime::AppConfig::Attribute

=head1 ATTRIBUTES

=cut

has 'version' => (
    is => 'rw',
);

sub _check_type {
    my ($self, $value) = @_;
    my $def = $self->{definition};
    $self->{_json_string} //= $def->{isa} eq 'json_string' ? 1 : 0;
    if ($self->{_json_string}) {
        try { $value = decode_json($value) } catch { croak "Couldn't decode JSON attribute" };
    } else {
        $self->{_type_constraint} //= find_type_constraint($def->{isa});
        unless ($self->{_type_constraint}) {
            croak "Couldn't find type constraint for " . $def->{isa} . " for " . $self->name;
        }
        $self->{_type_constraint}->check($value) or croak $self->name . " expecting a value of type " . $def->{isa};
    }
    return;
}

sub value {
    my ($self, $value) = @_;

    if (defined $value) {
        $self->_check_type($value);
        $self->{_value} = $value;
        $self->_set_value($value);
        $self->version($self->data_set->{version});    #Avoids building after set unless version changed.
    } else {
        if (not $self->version or $self->version ne $self->data_set->{version}) {
            my $val = $self->_build_value;
            if (defined $val) {
                $self->value($val);
                $self->version($self->data_set->{version});
            }
        }
    }

    return $self->{_value};
}

sub build {
    my $self    = shift;
    my $default = $self->definition->{default};
    $self->_check_type($default);
    $self->{_value} = $default;
    return $self;
}

sub is_bool_type {
    my $self = shift;
    return ($self->definition and uc $self->definition->{isa} eq 'BOOL');
}

sub _build_value {
    my $self = shift;
    my $value;
    $value //= $self->data_set->{app_config}->get($self->path) if ($self->data_set->{app_config});
    $value //= $self->definition->{default} if ($self->definition);

    return $value;
}

sub _set_value {
    return;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2013 RMG Technology (M) Sdn Bhd

=cut
