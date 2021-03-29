package BOM::Pricing::v3::Utility;

use strict;
use warnings;

use DataDog::DogStatsd::Helper qw(stats_inc);
use JSON::MaybeUTF8 qw(:v1);
use BOM::Config::Redis;
use BOM::Product::Contract;
use Price::Calculator;
use Math::Util::CalculatedValue::Validatable;
use Format::Util::Numbers qw/financialrounding/;
use List::Util qw(min);

use constant POC_PARAMETERS => 'POC_PARAMETERS';

sub create_error {
    my $args = shift;
    stats_inc("bom_pricing_rpc.v_3.error", {tags => ['code:' . $args->{code},]});
    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{continue_price_stream} ? (continue_price_stream => $args->{continue_price_stream}) : (),
            $args->{message}               ? (message               => $args->{message})               : (),
            $args->{details}               ? (details               => $args->{details})               : ()}};
}

=head2 update_price_metrics

Updates the price metrics in redis. Like the quantity processed
and the total timing.

=over 4

=item * C<relative_shortcode> - the relative shortcode to be used as field name

=item * C<timing> - the price timing

=back

=cut

sub update_price_metrics {
    my ($relative_shortcode, $timing) = @_;

    my $redis_pricer = BOM::Config::Redis::redis_pricer;

    $redis_pricer->hincrby('PRICE_METRICS::COUNT', $relative_shortcode, 1);
    $redis_pricer->hincrbyfloat('PRICE_METRICS::TIMING', $relative_shortcode, $timing);

    return;
}

=head2 create_relative_shortcode

Creates a relative shortcode using the contract parameters.

=over 4

=item * C<params> - Contract parameters

=back

Returns the relative shortcode.

=cut

sub create_relative_shortcode {
    my ($params, $current_spot) = @_;

    return BOM::Product::Contract->get_relative_shortcode($params->{short_code})
        if (exists $params->{short_code});

    $params->{date_start} //= 0;
    my $date_start = $params->{date_start} ? int($params->{date_start} - time) . 'F' : '0';

    my $date_expiry;
    if ($params->{date_expiry}) {
        $date_expiry = ($params->{date_expiry} - ($params->{date_start} || time)) . 'F';
    } elsif (defined $params->{duration} and defined $params->{duration_unit}) {
        if ($params->{duration_unit} eq 't') {
            $date_expiry = $params->{duration} . 'T';
        } else {
            my %map_to_seconds = (
                s => 1,
                m => 60,
                h => 3600,
                d => 86400,
            );
            $date_expiry = $params->{duration} * $map_to_seconds{$params->{duration_unit}};
        }
    }

    $date_expiry //= 0;

    my @barriers = ($params->{barrier} // 'S0P', $params->{barrier2} // '0');

    if ($params->{contract_type} !~ /digit/i) {
        @barriers = map { BOM::Product::Contract->to_relative_barrier($_, $current_spot, $params->{symbol}) } @barriers;
    }

    return uc join '_', ($params->{contract_type}, $params->{symbol}, $date_start, $date_expiry, @barriers);
}

sub non_binary_price_adjustment {
    my ($contract_parameters, $response) = @_;

    my $theo_price = delete $response->{'theo_price'};

    # apply app markup adjustment here:
    my $app_markup_percentage = $contract_parameters->{app_markup_percentage} // 0;
    my $multiplier            = $contract_parameters->{multiplier}            // 0;

    my $app_markup_per_unit = $theo_price * $app_markup_percentage / 100;
    my $app_markup          = $multiplier * $app_markup_per_unit;

    # currently we only have 2 non-binary contracts:
    # - lookback
    # - callput_spread
    my $adjusted_ask_price = $response->{ask_price} + $app_markup;

    # callput_spread has maximum ask price
    if (exists $contract_parameters->{maximum_ask_price}) {
        $adjusted_ask_price = min($contract_parameters->{maximum_ask_price}, $adjusted_ask_price);
    }

    $response->{ask_price} = $response->{display_value} =
        financialrounding('price', $contract_parameters->{currency}, $adjusted_ask_price);

    return $response;
}

sub binary_price_adjustment {
    my ($contract_parameters, $response) = @_;

    # overrides the theo_probability, which takes the most calculation time.
    # theo_probability is a calculated value (CV), overwrite it with CV object.
    my $resp_theo_probability = delete $response->{theo_probability};
    my $theo_probability      = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theo_probability',
        description => 'theorectical value of a contract',
        set_by      => 'Pricer Daemon',
        base_amount => $resp_theo_probability,
        minimum     => 0,
        maximum     => 1,
    });

    my $cps              = $contract_parameters;
    my $price_calculator = Price::Calculator->new({
        currency              => $cps->{currency},
        amount                => $cps->{amount},
        amount_type           => $cps->{amount_type},
        app_markup_percentage => $cps->{app_markup_percentage},
        deep_otm_threshold    => $cps->{deep_otm_threshold},
        base_commission       => $cps->{base_commission},
        min_commission_amount => $cps->{min_commission_amount},
        $cps->{staking_limits} ? (staking_limits => $cps->{staking_limits}) : (),
        theo_probability => $theo_probability
    });

    if (my $error = $price_calculator->validate_price) {
        my $error_map = {
            zero_stake             => "Invalid stake/payout.",
            payout_too_many_places => 'Payout can not have more than [_1] decimal places.',
            stake_too_many_places  => 'Stake can not have more than [_1] decimal places.',
            stake_same_as_payout   => 'This contract offers no return.',
            stake_outside_range    => 'Minimum stake of [_1] and maximum payout of [_2]. Current stake is [_3].',
            payout_outside_range   => 'Minimum stake of [_1] and maximum payout of [_2]. Current stake is [_3].',
        };
        # FIXME: use the error_mappings in Static.pm
        # my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

        return create_error({
            # FIXME: price_calculator error codes are the wrong format
            code              => $error->{error_code},
            message_to_client => [$error_map->{$error->{error_code}}, @{$error->{error_details} // []}],
        });
    }

    $response->{ask_price}     = $price_calculator->ask_price;
    $response->{display_value} = financialrounding('price', $cps->{currency}, $response->{ask_price});
    $response->{payout}        = $price_calculator->payout;
    $response->{$_} .= '' for qw(ask_price display_value payout);

    return $response;
}

=head2 create_relative_shortcode
Get proposal-open-contract prameters from redis-pricer-shared.
=cut

sub get_poc_parameters {
    my ($contract_id, $landing_company) = @_;

    my $redis_read = BOM::Config::Redis::redis_pricer_shared(timeout => 0);
    my $params_key = join '::', (POC_PARAMETERS, $contract_id, $landing_company);
    my $params     = $redis_read->get($params_key);

    # Returns empty hash reference if could not find contract parameters.
    # This will then fail in validation.
    return {} unless $params;

    # refreshes the expiry to 10 seconds if TTL is less.
    BOM::Config::Redis::redis_pricer_shared_write()->expire($params_key, 10) if $redis_read->ttl($params_key) < 10;

    my $payload        = decode_json_utf8($params);
    my $poc_parameters = {@{$payload}};

    return $poc_parameters;
}

1;
