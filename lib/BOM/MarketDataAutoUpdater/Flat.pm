package BOM::MarketDataAutoUpdater::Flat;

=head1 NAME

BOM::MarketDataAutoUpdater::Flat

=head1 DESCRIPTION

Auto-updates financial instruments that have flat volatility.

For cleaner pricing engines code, we should not have to handle exception for instruments that have flat volatility.

=cut

use Moose;
use Finance::Asset::Market::Registry;
use Quant::Framework::VolSurface::Delta;
use Quant::Framework::VolSurface::Moneyness;
use Date::Utility;
use BOM::Config::Chronicle;
use BOM::MarketData qw(create_underlying create_underlying_db);

=head2 symbols_for_delta

A list of symbols that has flat delta surface.

=cut

has symbols_for_delta => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_symbols_for_delta {
    my $self = shift;

    return [map { $_->symbol } grep { $_->volatility_surface_type eq 'delta' } @{$self->all_symbols}];
}

=head2 symbols_for_moneyness

A list of symbols that has flat moneyness surface.

=cut

has symbols_for_moneyness => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_symbols_for_moneyness {
    my $self = shift;

    return [map { $_->symbol } grep { $_->volatility_surface_type eq 'moneyness' } @{$self->all_symbols}];
}

has all_symbols => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_all_symbols {
    my $self      = shift;
    my %skip_list = map { $_ => 1 } (@{BOM::Config::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol});
    my @markets   = Finance::Asset::Market::Registry->instance->all_market_names();
    return [
        grep { $_->flat_smile }
        map { create_underlying($_) } grep { not $skip_list{$_} } create_underlying_db->get_symbols_for(market => [@markets])];
}

=head2 run

Constructs delta/moneyness surface data for the list of instruments and save them.

=cut

sub run {
    my $self = shift;

    my $now    = Date::Utility->new;
    my @tenors = qw(1 7 40 90 180 360);
    my ($chronicle_r, $chronicle_w) = (BOM::Config::Chronicle::get_chronicle_reader, BOM::Config::Chronicle::get_chronicle_writer);

    foreach my $symbol (@{$self->symbols_for_delta}) {
        my $surface_data = {map { $_ => {vol_spread => _get_volspread('delta'), smile => _get_smile('delta')} } @tenors};
        Quant::Framework::VolSurface::Delta->new({
                underlying       => create_underlying($symbol),
                surface_data     => $surface_data,
                creation_date    => $now,
                chronicle_reader => $chronicle_r,
                chronicle_writer => $chronicle_w,
            })->save;
    }

    foreach my $symbol (@{$self->symbols_for_moneyness}) {
        my $surface_data = {map { $_ => {vol_spread => _get_volspread('moneyness'), smile => _get_smile('moneyness')} } @tenors};
        my $underlying   = create_underlying($symbol);
        Quant::Framework::VolSurface::Moneyness->new({
                underlying       => $underlying,
                surface_data     => $surface_data,
                creation_date    => $now,
                chronicle_reader => $chronicle_r,
                chronicle_writer => $chronicle_w,
                spot_reference   => $underlying->spot,
            })->save;
    }

    return 1;
}

sub _get_volspread {
    my $type = shift;

    return $type eq 'delta' ? {50 => 0} : {100 => 0};
}

sub _get_smile {
    my $type = shift;

    my %smile_point = (
        delta     => [25, 50, 75],
        moneyness => [90, 92, 94, 96, 98, 100, 102, 104, 106, 108, 110],
    );

    return {map { $_ => 0.1 } @{$smile_point{$type}}};
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
