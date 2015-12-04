package BOM::Product::Role::ExpireAtEnd;

use Moose::Role;

use Time::Duration::Concise;
use BOM::Platform::Context qw(localize);
use BOM::Utility::ErrorStrings qw( format_error_string );

sub _build_is_expired {
    my $self = shift;

    return 0 unless ($self->is_after_expiry and $self->exit_tick);

    $self->check_expiry_conditions;

    return 1;
}

1;
