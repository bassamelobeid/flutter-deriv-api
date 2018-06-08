package BOM::Product::Contract::Ticklow;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry', 'BOM::Product::Role::HighLowTicks';

use List::Util qw/any/;

use Pricing::Engine::HighLowTicks;

use BOM::Product::Pricing::Greeks::ZeroGreek;

sub check_expiry_conditions {

    my $self = shift;

    my $ticks = $self->underlying->ticks_in_between_start_limit({
        start_time => $self->date_start->epoch + 1,
        limit      => $self->ticks_to_expiry,
    });

    my $number_of_ticks = scalar(@$ticks);

    # Do not evaluate until we have the selected tick
    return 0 if $number_of_ticks < $self->selected_tick;

    # If there's no tick yet, the contract is not expired.
    return 0 unless $self->barrier;

    # selected quote is not the lowest.
    if ($self->calculate_highlow_hit_tick) {
        $self->value(0);
        return 1;    # contract expired
    }

    # we already have the full set of ticks, but no tick is lower than selected.
    if ($number_of_ticks == $self->ticks_to_expiry) {
        $self->value($self->payout);
        return 1;
    }

    # not expired, still waiting for ticks.
    return 0;

}

# Returns a hash of permitted inputs
sub get_permissible_inputs {
    return {
        # Contract-relevant inputs
        'ask_price'     => 1,
        'bet_type'      => 1,
        'underlying'    => 1,
        'amount_type'   => 1,
        'amount'        => 1,
        'date_start'    => 1,
        'selected_tick' => 1,
        'date_expiry'   => 1,
        'currency'      => 1,
        'payout'        => 1,
        'basis'         => 1,
        'symbol'        => 1,

        # Stake inputs
        'starts_as_forward_starting' => 1,
        'payouttime'                 => 1,
        'pricing_new'                => 1,
        'payout_type'                => 1,
        'base_commission'            => 1,
        'category'                   => 1,
        'has_user_defined_barrier'   => 1,
        'pricing_code'               => 1,
        'id'                         => 1,
        'sentiment'                  => 1,
        'display_name'               => 1,
        'other_side_code'            => 1,

        # Proposal inputs
        'country_code' => 1,
        'product_type' => 1,
        'proposal'     => 1,

        # Metadata inputs
        'shortcode'              => 1,
        'duration'               => 1,
        'duration_unit'          => 1,
        'date_pricing'           => 1,
        'fixed_expiry'           => 1,
        'tick_expiry'            => 1,
        'tick_count'             => 1,
        'is_sold'                => 1,
        'contract_type'          => 1,
        'landing_company'        => 1,
        'app_markup_percentage'  => 1,
        'prediction'             => 1,
        'req_id'                 => 1,
        'subscribe'              => 1,
        'form_id'                => 1,
        'passthrough'            => 1,
        'price_daemon_cmd'       => 1,
        'skips_price_validation' => 1,
    };
}

sub _validate_barrier {
    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
