package BOM::Product::Contract::Batch;

use Moose;
use Format::Util::Numbers qw/formatnumber/;

use BOM::Product::Categorizer;
use BOM::Product::Static;

=head1 NAME

BOM::Product::Contract::Batch

=head1 DESCRIPTION

A class that handles one/multiple contract types and/or one/multiple barriers.

A little optimization in market data handling is done here, where the contracts share common market data like volatility surface, spot price, interest rates, etc.

=head1 USAGE

    my $batch = BOM::Product::Contract::Batch->new(parameters => {
        bet_types => ['CALL', 'PUT'],
        barriers => ['S0P', 'S10P', 'S-10P'],
        ...
    });

    $batch->ask_prices;

=cut

has parameters => (
    is       => 'ro',
    required => 1,
);

has _contracts => (
    is         => 'ro',
    lazy_build => 1,
);

has underlying => (
    is         => 'ro',
    lazy_build => 1,
    handles    => [qw(market pip_size)],
);

sub _build_underlying {
    my ($self) = @_;
    return $self->_contracts->[0]->underlying;
}

sub _build__contracts {
    my $self = shift;

    my $method_ref = delete $self->parameters->{_produce_contract_ref};
    # Categorizer's process always returns ARRAYREF
    my $params = BOM::Product::Categorizer->new(parameters => $self->parameters)->process();

    my $first_param = shift @$params;
    $first_param->{processed} = 1;
    my $first_contract = $method_ref->($first_param);

    my %similar_market_data = (
        current_tick => $first_contract->current_tick,
        q_rate       => $first_contract->q_rate,
        r_rate       => $first_contract->r_rate,
        volsurface   => $first_contract->volsurface,
    );

    if ($first_contract->priced_with_intraday_model) {
        # intraday model uses intradayfx volatility which is the same across barriers
        $similar_market_data{pricing_vol}          = $first_contract->pricing_vol;
        $similar_market_data{empirical_volsurface} = $first_contract->empirical_volsurface;
        $similar_market_data{long_term_prediction} = $first_contract->long_term_prediction;
    } else {
        $similar_market_data{volsurface} = $first_contract->volsurface;
    }

    my @contracts = ($first_contract);
    foreach my $param (@$params) {
        push @contracts, $method_ref->(+{%$param, %similar_market_data, processed => 1});
    }

    return \@contracts;
}

=head2 ask_prices

Returns a hash reference of contract prices in the following format:

{
    $contract_type => {
        $barrier1 => {
            # if it is valid to buy
            theo_probability => ...,
            longcode => ...,
            ask_price => ...,
            display_value => ...,
            barrier => ..., # for single barrier contracts. high_barrier & low_barrier for double barrier contracts.
        },
        $barrier2 => {
            $ if it is invalid
            error => ...,
            message_to_client => ...,
        }
    },
    $contract_type2 => {
        ...
    },
}

=cut

sub ask_prices {
    my $self = shift;

    my %prices;
    foreach my $contract (@{$self->_contracts}) {
        my $barrier_key =
            $contract->two_barriers
            ? ($contract->high_barrier->as_absolute) . '-' . ($contract->low_barrier->as_absolute)
            : ($contract->barrier->as_absolute);
        my $contract_info = ($prices{$contract->code}{$barrier_key} //= {});
        if ($contract->is_valid_to_buy) {
            $contract_info->{$_} = $contract->$_ for qw(ask_price longcode);
            $contract_info->{theo_probability} = $contract->theo_probability->amount;
            $contract_info->{display_value}    = $contract->ask_price;
            if ($contract->two_barriers) {
                $contract_info->{barrier}  = ($contract->high_barrier->as_absolute);
                $contract_info->{barrier2} = ($contract->low_barrier->as_absolute);
            } else {
                $contract_info->{barrier} = ($contract->barrier->as_absolute);
            }
        } else {
            if (my $pve = $contract->primary_validation_error) {
                $contract_info->{error} = {
                    code              => 'ContractBuyValidationError',
                    message_to_client => $pve->message_to_client
                };
            } else {
                $contract_info->{error} = {
                    code              => 'ContractValidationError',
                    message_to_client => [BOM::Product::Static::get_error_mapping()->{CannotValidateContract}],
                    details           => {},
                };
            }
            # When the date_expiry is smaller than date_start, we can not price, display the payout|stake on error message
            if ($contract->date_expiry->epoch <= $contract->date_start->epoch) {

                my $display_value =
                      $contract->has_payout
                    ? $contract->payout
                    : $contract->ask_price;
                $contract_info->{error}{details} = {
                    display_value => formatnumber('price', $contract->currency, $display_value),
                    payout        => formatnumber('price', $contract->currency, $display_value),
                };
            } else {
                $contract_info->{error}{details} = {
                    display_value => formatnumber('price', $contract->currency, $contract->ask_price),
                    payout        => formatnumber('price', $contract->currency, $contract->payout),
                };
            }
            if ($contract->two_barriers) {
                $contract_info->{error}{details}{barrier}  = ($contract->high_barrier->as_absolute);
                $contract_info->{error}{details}{barrier2} = ($contract->low_barrier->as_absolute);
            } else {
                $contract_info->{error}{details}{barrier} = ($contract->barrier->as_absolute);
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
        spot_time             => $contract->current_tick->epoch,
        date_start            => $contract->date_start->epoch,
        app_markup_percentage => $contract->app_markup_percentage,
        staking_limits        => $contract->staking_limits,
        deep_otm_threshold    => $contract->otm_threshold,
        base_commission       => $contract->base_commission,
    );
    $details{spot} = $contract->current_spot if $contract->underlying->feed_license eq 'realtime';
    return \%details;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
