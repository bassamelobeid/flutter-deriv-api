package BOM::Product::Role::ExpireAtEnd;

use Moose::Role;

use Time::Duration::Concise;
use BOM::Platform::Context qw(localize);

sub _build_is_expired {
    my $self = shift;

    # As long as it already pass the expiry time and have exit tick, it is consider expired.
    # is_valid_to_sell will stop it from sell as it has not pass the settlement time
    return 0 unless ($self->is_after_expiry and $self->exit_tick);

    $self->check_expiry_conditions;

    return 1;
}

1;
