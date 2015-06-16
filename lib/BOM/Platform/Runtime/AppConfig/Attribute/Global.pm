package BOM::Platform::Runtime::AppConfig::Attribute::Global;

use Moose;
use Carp;
extends 'BOM::Platform::Runtime::AppConfig::Attribute';

=head1 NAME

BOM::Platform::Runtime::AppConfig::Attribute::Global

=cut

sub _build_value {
    my $self = shift;
    my $value;
    $value //= $self->data_set->{app_settings_overrides}->get($self->path) if ($self->data_set->{app_settings_overrides});
    $value //= $self->data_set->{global}->get($self->path)                 if ($self->data_set->{global});
    $value //= $self->data_set->{app_config}->get($self->path)             if ($self->data_set->{app_config});
    $value //= $self->definition->{default}                                if ($self->definition);

    return $value;
}

sub _set_value {
    my $self  = shift;
    my $value = shift;
    $self->data_set->{global}->set($self->path, $value) if ($self->data_set->{global});
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2013 RMG Technology (M) Sdn Bhd

=cut
