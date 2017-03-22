package BOM::Product::Contract::BatchContract;

use Moose;
use BOM::Product::Categorizer;
use BOM::Platform::Context qw (localize);

has parameters => (
    is       => 'ro',
    required => 1,
);

has _contracts => (
    is         => 'ro',
    lazy_build => 1,
);

has underlying => (
    is      => 'ro',
    lazy_build => 1,
    handles => [qw(market pip_size)],
);

sub _build_underlying {
    my ($self) = @_;
    return $self->_contracts->[0]->underlying;
}

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
            ? (0+$contract->high_barrier->as_absolute) . '-' . (0+$contract->low_barrier->as_absolute)
            : (0+$contract->barrier->as_absolute);
        my $contract_info = ($prices{$contract->code}{$barrier_key} //= {});
        if ($contract->is_valid_to_buy) {
            $contract_info->{$_} = $contract->$_ for qw(ask_price longcode);
            $contract_info->{theo_probability} = $contract->theo_probability->amount;
            $contract_info->{display_value} = $contract->ask_price;
        } else {
            if (my $pve = $contract->primary_validation_error) {
                $contract_info->{error} = {
                    code => 'ContractBuyValidationError',
                    message_to_client => $pve->message_to_client
                };
            } else {
                $contract_info->{error} = {
                    code => 'ContractValidationError',
                    message_to_client => localize("Cannot validate contract")
                };
            }
            # When the date_expiry is smaller than date_start, we can not price, display the payout|stake on error message
            if ($contract->date_expiry->epoch <= $contract->date_start->epoch) {

                my $display_value =
                      $contract->has_payout
                    ? $contract->payout
                    : $contract->ask_price;
                $contract_info->{error}{details} = {
                    display_value => (
                          $contract->is_spread
                        ? $contract->buy_level
                        : sprintf('%.2f', $display_value)
                    ),
                    payout => sprintf('%.2f', $display_value),
                };
            } else {
                $contract_info->{error}{details} = {
                    display_value => (
                          $contract->is_spread
                        ? $contract->buy_level
                        : sprintf('%.2f', $contract->ask_price)
                    ),
                    payout => sprintf('%.2f', $contract->payout),
                };
            }
            if( $contract->two_barriers ) {
                $contract_info->{error}{details}{barrier} = (0+$contract->high_barrier->as_absolute);
                $contract_info->{error}{details}{barrier2} = (0+$contract->low_barrier->as_absolute);
            } else {
                $contract_info->{error}{details}{barrier} = (0+$contract->barrier->as_absolute);
            }
            # We want to record longcode if possible, but it may not always be available
            $contract_info->{longcode} = eval { $contract->longcode } || '';
        }
    }

    return \%prices;
}

sub market_details {
    my ($self) = @_;
    # We use the first contract to determine metadata that will be common
    # across all our contracts - underlying, dates, spot values etc.
    my ($contract) = @{$self->_contracts};
    my %details = (
        spot_time  => $contract->current_tick->epoch,
        date_start => $contract->date_start->epoch,
    );
    $details{spot} = $contract->current_spot if $contract->underlying->feed_license eq 'realtime';
    $details{spread} = $contract->spread if $contract->is_spread;
    return \%details;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
