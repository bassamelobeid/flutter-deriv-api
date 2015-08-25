package BOM::Product::Contract::Spreadd;

use Moose;
extends 'BOM::Product::Contract::Spread';
use Format::Util::Numbers qw(to_monetary_number_format roundnear);

use BOM::Platform::Context qw(localize);
use BOM::Product::Contract::Strike::Spread;
# Static methods

sub id              { return 260; }
sub code            { return 'SPREADD'; }
sub category_code   { return 'spreads'; }
sub display_name    { return 'spread down'; }
sub sentiment       { return 'down'; }
sub other_side_code { return 'SPREADU'; }
sub action          { return 'sell'; }

# The price of which the client bought at.
has barrier => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_barrier {
    my $self             = shift;
    my $supplied_barrier = $self->underlying->pipsized_value($self->entry_tick->quote - $self->half_spread);
    return BOM::Product::Contract::Strike::Spread->new(supplied_barrier => $supplied_barrier);
}

has [qw(stop_loss_level stop_profit_level)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_stop_loss_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->barrier->as_absolute + $self->stop_loss);
}

sub _build_stop_profit_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->barrier->as_absolute - $self->stop_profit);
}

sub _get_hit_level {
    my ($self, $high_hit, $low_hit) = @_;

    my $stop_level;
    if ($low_hit <= $self->stop_profit_level) {
        $stop_level = $self->stop_profit_level;
    } elsif ($high_hit >= $self->stop_loss_level) {
        $stop_level = $self->stop_loss_level;
    }

    return $stop_level;
}

has [qw(buy_level sell_level)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_buy_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->current_tick->quote - $self->half_spread);
}

sub _build_sell_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->current_tick->quote + $self->half_spread);
}

sub _recalculate_value {
    my ($self, $level) = @_;

    if ($level) {
        my $point_diff = $self->barrier->as_absolute - $level;
        my $value      = $point_diff * $self->amount_per_point;
        $self->_update($value, $point_diff);
    }

    return;
}

has _highlow_args => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__highlow_args {
    my $self        = shift;
    my $half_spread = $self->half_spread;
    return [$self->stop_loss_level - $half_spread, $self->stop_profit_level + $half_spread];
}

sub localizable_description {
    return {
        dollar =>
            'Payout of [_1] <strong>[_2]</strong> for every point [_3] <strong>falls</strong> from <strong>entry level</strong>, with stop loss of <strong>[_6] [_4]</strong> and stop profit of <strong>[_6] [_5]</strong>.',
        point =>
            'Payout of [_1] <strong>[_2]</strong> for every point [_3] <strong>falls</strong> from <strong>entry level</strong>, with stop loss of <strong>[_4] [plural,_4,point,points]</strong> and stop profit of <strong>[_5] [plural,_5,point,points]</strong>.',
    };
}

#VALIDATIONS
sub _validate_sell_consistency {
    my $self = shift;

    my @err;
    if (    $self->date_pricing->is_after($self->date_start)
        and not $self->is_expired
        and ($self->sell_level >= $self->stop_loss_level or $self->sell_level <= $self->stop_profit_level))
    {
        push @err,
            {
            message           => 'Feed has not been updated in feed database yet for[' . $self->underlying->symbol . ']',
            severity          => 98,
            message_to_client => localize('Sell on [_1] is pending due to missing market data.', $self->underlying->translated_display_name),
            };
    }

    return @err;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
