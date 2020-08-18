package BOM::MarketDataAutoUpdater::Script::UpdateSmartFxRates;

=head1 NAME

BOM::MarketDataAutoUpdater::Script::UpdateSmartFxRates


=head1 DESCRIPTION

Update interest rate of smart fx based on the interest rate of the forex pairs of the basket

=cut

use Moose;
with 'App::Base::Script';

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Quant::Framework::InterestRate;
use Date::Utility;

# World FX is an index that measure value of a currency against a basket of major Forex pairs.
# The interest rate of a World FX is the aggregrate interest rate of the basket of Forex pairs.
# For those Forex pair that we long will have positive interest rate and for those that we short will have negative interest rate
has world_symbols => (
    is      => 'ro',
    default => sub {
        {
            WLDUSD => {
                source   => [qw(frxEURUSD frxUSDJPY frxGBPUSD frxUSDCAD frxAUDUSD)],
                negative => [qw(frxGBPUSD frxEURUSD frxAUDUSD)]
            },
            WLDAUD => {
                source   => [qw(frxAUDCAD frxAUDJPY frxAUDUSD frxEURAUD frxGBPAUD)],
                negative => [qw(frxEURAUD frxGBPAUD)]
            },
            WLDEUR => {
                source   => [qw(frxEURAUD frxEURCAD frxEURGBP frxEURJPY frxEURUSD)],
                negative => [qw()]
            },
            WLDGBP => {
                source   => [qw(frxEURGBP frxGBPAUD frxGBPCAD frxGBPJPY frxGBPUSD)],
                negative => [qw(EURGBP)]
            },
        };
    },
);

sub documentation {
    return 'updates smart fx interest rates.';
}

sub script_run {
    my $self = shift;

    my $world         = $self->world_symbols;
    my @smart_symbols = keys %$world;
    foreach my $symbol (@smart_symbols) {
        my %neg  = map { $_ => 1 } @{$world->{$symbol}->{negative}};
        my $date = Date::Utility->new();
        next if $date->is_a_weekend;
        my @source = map { create_underlying($_) } @{$self->world_symbols->{$symbol}->{source}};
        my %world_rate;
        for my $term (
            sort { $a <=> $b } keys %{Quant::Framework::InterestRate->new({
                        symbol           => 'USD',
                        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
                        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
                    }
                )->rates
            })
        {
            my %rates       = map { $_->symbol => $_->interest_rate_for($term / 365) - $_->dividend_rate_for($term / 365) } @source;
            my @rates_array = map { $neg{$_->symbol} ? -$rates{$_->symbol} : $rates{$_->symbol} } @source;
            $world_rate{$term} = ($rates_array[0] + $rates_array[1] + $rates_array[2] + $rates_array[3] + $rates_array[4]) / 5;
        }
        my $ir = Quant::Framework::InterestRate->new({
            symbol           => $symbol,
            rates            => \%world_rate,
            recorded_date    => $date,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        });
        $ir->save;
    }

    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
