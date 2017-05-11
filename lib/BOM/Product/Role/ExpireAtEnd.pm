package BOM::Product::Role::ExpireAtEnd;

use Moose::Role;
use Time::Duration::Concise;

override is_expired => sub {
    my $self = shift;

    # As long as it already pass the expiry time and have exit tick, it is consider expired.
    # is_valid_to_sell will stop it from sell as it has not pass the settlement time
    return 0 unless ($self->is_after_expiry and $self->exit_tick);

    $self->check_expiry_conditions;

    return 1;
};

override is_settleable => sub {
    my $self = shift;

    my $settleable = ($self->is_after_settlement and $self->exit_tick and $self->is_valid_exit_tick) ? 1 : 0;

    return $settleable;
};

1;
