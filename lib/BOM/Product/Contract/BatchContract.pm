package BOM::Product::BatchContract;

use Moose;

use BOM::Product::Categorizer;

has parameters => (
    is       => 'ro',
    required => 1,
);

has _contracts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__contracts {
    my $self = shift;

    my $method_ref  = delete $self->parameters->{_produce_contract_ref};
    my $categorizer = BOM::Product::Categorizer->new(parameters => $self->parameters);
    my $params      = $categorizer->process();

    my @contracts;
    foreach my $param (@$params) {
        $params->{processed} = 1;
        push @contracts, $method_ref->($params);
    }

    return \@contracts;
}

sub ask_prices {
    my $self = shift;

    my %prices;
    foreach my $contract (@{$self->_contracts}) {
        my $barrier_key =
              $contract->two_barriers
            ? $contract->high_barrier->as_absolute . '-' . $contract->low_barrier->as_absolute
            : $contract->barrier->as_absolute;
        if ($contract->is_valid_to_buy) {
            $prices{$contract->code}{$barrier_key}{ask_price}     = $contract->ask_price;
            $prices{$contract->code}{$barrier_key}{display_value} = $contract->ask_price;
            $prices{$contract->code}{$barrier_key}{longcode}      = $contract->longcode;
        } else {
            $prices{$contract->code}{$barrier_key}{error} = $contract->primary_validation_error->message_to_client;
        }
    }

    return \%prices;
}

sub bid_prices {
    my $self = shift;

    my %prices;
    foreach my $contract (@{$self->_contracts}) {
        my $barrier_key =
              $contract->two_barriers
            ? $contract->high_barrier->as_absolute . '-' . $contract->low_barrier->as_absolute
            : $contract->barrier->as_absolute;
        if ($contract->is_valid_to_sell) {
            $prices{$contract->code}{$barrier_key}{ask_price}     = $contract->bid_price;
            $prices{$contract->code}{$barrier_key}{display_value} = $contract->bid_price;
            $prices{$contract->code}{$barrier_key}{longcode}      = $contract->longcode;
        } else {
            $prices{$contract->code}{$barrier_key}{error} = $contract->primary_validation_error->message_to_client;
        }
    }

    return \%prices;
}

no Moose;
__PACKAGE->meta->make_immutable;
1;
