package BOM::Product::Role::ExpireAtEnd;

use Moose::Role;

override is_expired => sub {
    my $self = shift;

    # for forward starting contract, contract is expired if entry tick is staled for more than
    # the maximum allowed feed delay before the contract starts.
    return 1
        if $self->starts_as_forward_starting
        and $self->entry_tick
        and $self->date_start->epoch - $self->entry_tick->epoch > $self->underlying->max_suspend_trading_feed_delay->seconds;

    # for contract starting now, contract is only considered expired after the expiration time
    return 0 unless $self->is_after_expiry;

    $self->check_expiry_conditions;
    return 1;
};

1;
