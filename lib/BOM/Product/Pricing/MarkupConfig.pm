package BOM::Product::Pricing::MarkupConfig;

use 5.010;
use Moose;

use YAML::CacheLoader qw(LoadFile);
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Utils;
use BOM::MarketData::Fetcher::VolSurface;

has [qw(underlying date_start date_expiry)] => (
    is       => 'ro',
    required => 1,
);

sub coef {
    state $coef = LoadFile('markup_config.yml');
    return $coef;
}

sub traded_market_markup {
    my $self = shift;

    return $self->coef->{traded_market}->{$self->underlying->market->name} // 0;
}

sub economic_events_markup {
    my $self = shift;

    return if not $self->coef->{affected_by_economic_event}->{$self->underlying->market->name};
    return if ($self->date_expiry->epoch - $self->date_start->epoch) > 86400;
    return 1;
}

sub end_of_day_markup {
    my $self = shift;

    return if not $self->coef->{affected_by_eod_risk}->{$self->underlying->market->name};
    my $contract_duration = ($self->date_expiry->epoch - $self->date_start->epoch) / 86400;
    return if $contract_duration > 3;
    my $ny_1600 = BOM::MarketData::VolSurface::Utils->new->NY1700_rollover_date_on($self->date_start)->minus_time_interval('1h');
    return 1 if ($ny_1600->is_before($self->date_start) or ($contract_duration <= 1 and $ny_1600->is_before($self->date_expiry)));
    return;
}

sub butterfly_markup {
    my $self = shift;

    return if not $self->coef->{affected_by_butterfly_risk}->{$self->underlying->market->name};
    return if (($self->date_expiry->epoch - $self->date_start->epoch) / 86400 > 7);
    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $self->underlying});
    my $first_term = $volsurface->original_term_for_smile->[0];
    return if $first_term != $volsurface->_ON_day;
    return if $volsurface->get_market_rr_bf($first_term)->{BF_25} < 0.01;
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
