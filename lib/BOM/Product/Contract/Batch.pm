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

    my $batch = BOM::Product::Contract::Batch->new(
        parameters => [
            {
                bet_type => 'CALL',
                underlying => 'R_100',
                ...
            },
            {
                bet_type => 'PUT',
                underlying => 'R_100',
                ...
            }
        ],
        produce_contract_ref => sub {},
    );

    $batch->ask_prices;

=cut

has parameters => (
    is       => 'ro',
    required => 1,
);

has produce_contract_ref => (
    is       => 'ro',
    required => 1,
);

sub BUILD {
    my $self = shift;

    my @contracts;
    my %shared_contract_info;
    foreach my $params (@{$self->parameters}) {
        my $contract = $self->produce_contract_ref->(+{%$params, %shared_contract_info});
        unless (%shared_contract_info) {
            %shared_contract_info = (
                current_tick          => $contract->current_tick,
                q_rate                => $contract->q_rate,
                r_rate                => $contract->r_rate,
                volsurface            => $contract->volsurface,
                date_start            => $contract->date_start,
                pricing_new           => $contract->pricing_new,
                app_markup_percentage => $contract->app_markup_percentage,
                staking_limits        => $contract->staking_limits,
                deep_otm_threshold    => $contract->otm_threshold,
                base_commission       => $contract->base_commission,
                underlying            => $contract->underlying,
            );

            if ($contract->priced_with_intraday_model) {
                # intraday model uses intradayfx volatility which is the same across barriers
                $shared_contract_info{pricing_vol}          = $contract->pricing_vol;
                $shared_contract_info{empirical_volsurface} = $contract->empirical_volsurface;
                $shared_contract_info{long_term_prediction} = $contract->long_term_prediction;
            }
        }
        push @contracts, $contract;
    }

    $self->_shared_contract_info(\%shared_contract_info);
    $self->_contracts(\@contracts);

    return;
}

has [qw(_contracts _shared_contract_info)] => (
    is       => 'rw',
    init_arg => undef,
);

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
                $contract_info->{barrier}           = ($contract->high_barrier->as_absolute);
                $contract_info->{barrier2}          = ($contract->low_barrier->as_absolute);
                $contract_info->{supplied_barrier}  = ($contract->high_barrier->supplied_barrier);
                $contract_info->{supplied_barrier2} = ($contract->low_barrier->supplied_barrier);
            } else {
                $contract_info->{barrier}          = ($contract->barrier->as_absolute);
                $contract_info->{supplied_barrier} = ($contract->barrier->supplied_barrier);
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
    my $self = shift;

    my $shared = $self->_shared_contract_info();

    return {
        ($shared->{current_tick} ? (spot_time => $shared->{current_tick}->epoch) : ()),
        date_start            => $shared->{date_start}->epoch,
        app_markup_percentage => $shared->{app_markup_percentage},
        staking_limits        => $shared->{staking_limits},
        deep_otm_threshold    => $shared->{otm_threshold},
        base_commission       => $shared->{base_commission},
        ($shared->{underlying}->feed_license eq 'realtime' ? (spot => $shared->{current_tick}->quote) : ()),
    };
}

sub underlying {
    my $self = shift;
    return $self->_shared_contract_info->{underlying};
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
