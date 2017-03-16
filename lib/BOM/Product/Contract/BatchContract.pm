package BOM::Product::Contract::BatchContract;

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

    my $first_param = shift @$params;
    $first_param->{processed} = 1;
    my $first_contract = $method_ref->($first_param);

    my %similar_market_data = (
        current_tick => $first_contract->current_tick,
        q_rate       => $first_contract->q_rate,
        r_rate       => $first_contract->r_rate,
    );

    if ($first_contract->priced_with_intraday_model) {
        # intraday model uses empirical volatility which is the same across barriers
        $similar_market_data{pricing_vol}               = $first_contract->pricing_vol;
        $similar_market_data{news_adjusted_pricing_vol} = $first_contract->news_adjusted_pricing_vol;
        $similar_market_data{empirical_volsurface}      = $first_contract->empirical_volsurface;
    } else {
        $similar_market_data{volsurface} = $first_contract->volsurface;
    }

    my @contracts = ($first_contract);
    foreach my $param (@$params) {
        push @contracts, $method_ref->(+{%$param, %similar_market_data, processed => 1});
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

no Moose;
__PACKAGE__->meta->make_immutable;
1;
