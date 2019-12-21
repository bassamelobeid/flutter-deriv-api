package BOM::MarketDataAutoUpdater::Forex;

=head1 NAME

BOM::MarketDataAutoUpdater::Forex

=head1 DESCRIPTION

Auto-updates Forex vols.

=cut

use Moose;
extends 'BOM::MarketDataAutoUpdater';

use Bloomberg::FileDownloader;
use Bloomberg::VolSurfaces::BVOL;
use Bloomberg::VolSurfaces::BBDL;
use Date::Utility;
use File::Find::Rule;
use List::Util qw( first );
use LandingCompany::Registry;
use Quant::Framework::VolSurface::Delta;
use Quant::Framework::VolSurface::Utils qw(NY1700_rollover_date_on);
use Quant::Framework;
use Try::Tiny;

use BOM::MarketData qw(create_underlying create_underlying_db);
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::Types;
use BOM::Config::Chronicle;
use BOM::Config::Runtime;

has update_for => (
    is       => 'ro',
    required => 1,
);

has source => (
    is => 'ro',
);

has input_market => (
    is => 'ro',
);

has root_path => (
    is => 'ro',

);

has symbols_to_update => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_symbols_to_update {
    my $self  = shift;
    my @forex = create_underlying_db->get_symbols_for(
        market            => ['forex'],
        submarket         => ['major_pairs', 'minor_pairs'],
        contract_category => 'ANY',
    );
    my @commodities = create_underlying_db->get_symbols_for(
        market            => 'commodities',
        contract_category => 'ANY',
    );

    my @quanto_currencies = create_underlying_db->get_symbols_for(
        market      => ['forex', 'commodities',],
        quanto_only => 1,
    );
    my %skip_list =
        map { $_ => 1 } (
        @{BOM::Config::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol},
        qw(frxBROUSD frxBROAUD frxBROEUR frxBROGBP frxXPTAUD frxXPDAUD frxAUDSAR)
        );

    my @symbols;
    if ($self->source eq 'BBDL') {

        @symbols = grep { !$skip_list{$_} } (@quanto_currencies) if $self->update_for eq 'quanto';
        @symbols = grep { !$skip_list{$_} } (@forex, @commodities, @quanto_currencies) if $self->update_for eq 'all';

    } elsif ($self->source eq 'BVOL') {

        @symbols = grep { !$skip_list{$_} } (@forex, @commodities);

    } else {

        warn "unsupported source ";

    }

    return \@symbols;
}

has surfaces_from_file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_surfaces_from_file {
    my $self = shift;
    my (@volsurface, $vol_data, $surface);
    # For BBDL source, we are subscrbing full surface every 4 hours, the remaining hours , we only subscribe ON and 1W vol smile , hence it need to this appending with existing surface.
    if ($self->source eq 'BBDL') {
        $vol_data = Bloomberg::VolSurfaces::BBDL->new->parser($self->update_for, $self->root_path);
        $surface = $self->process_volsurface($vol_data);

        if ($self->update_for eq 'all') {
            foreach my $underlying (keys %{$surface}) {
                # We request full volsurface every 4 hours, hence on other hours, we will only get ON and 1W vol. Hence the vol point we are receiving will be just  2.
                if (scalar keys %{$surface->{$underlying}->{surface}} == 2) {
                    $surface->{$underlying}->{surface} = _append_to_existing_surface($surface->{$underlying}->{surface}, $underlying);
                }
            }
        }
        push @volsurface, $surface;
    } elsif ($self->source eq 'BVOL') {
        # For BVOL, due to pricing, we only get vol data of those offered pairs. For quanto, we still get from BBDL.
        $vol_data = Bloomberg::VolSurfaces::BVOL->new->parser($self->update_for, $self->root_path);
        $surface = $self->process_volsurface($vol_data);
        push @volsurface, $surface if defined $surface;
    }
    my $combined = {map { %$_ } @volsurface};
    return $combined;
}

=head1 METHODS

=head2 run

=cut

sub run {
    my $self = shift;

    my @quanto_currencies = create_underlying_db->get_symbols_for(
        market      => ['forex', 'commodities',],
        quanto_only => 1,
    );

    my $rollover_date           = NY1700_rollover_date_on(Date::Utility->new);
    my $one_hour_after_rollover = $rollover_date->plus_time_interval('1h');
    my $surfaces_from_file      = $self->surfaces_from_file;

    my @non_atm_symbol = LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config)
        ->query({barrier_category => ['euro_non_atm', 'american']}, ['underlying_symbol']);

    foreach my $symbol (@{$self->symbols_to_update}) {
        my $quanto_only = 'NO';
        if (grep { $_ eq $symbol } (@quanto_currencies)) {
            $quanto_only = "YES";
        }
        if (not $surfaces_from_file->{$symbol} and $quanto_only eq 'NO') {
            $self->report->{$symbol} = {
                success => 0,
                reason  => "Surface Information missing from datasource for $symbol. ",
                }
                if not $self->report->{$symbol};
            next;
        }
        my $underlying = create_underlying($symbol);
        # Forex contracts with flat smiles are updated with a different module (MarketDataAutoUpdater/Flat.pm)
        next if $underlying->flat_smile;
        my $raw_volsurface = $surfaces_from_file->{$symbol};
        unless (exists $raw_volsurface->{creation_date}) {
            warn "Volatility Surface data missing from provider for " . $underlying->symbol;
            next;    # skipping it here else it will die in the next line.
        }

        if (grep { $_ eq $symbol } (@non_atm_symbol)) {
            #skip this symbol if it is non atm and rr , bb are undef.
            if (exists $raw_volsurface->{rr_bf_status} and $raw_volsurface->{rr_bf_status}) {
                $self->report->{$symbol} = {
                    success => 0,
                    reason  => "BF or RR is undef ",
                };
                next;
            }
        }

        #Delete the flag since we do not need to save it into our system.
        delete $raw_volsurface->{rr_bf_status};

        next
            if $raw_volsurface->{creation_date}->epoch >= $rollover_date->epoch
            and $raw_volsurface->{creation_date}->epoch <= $one_hour_after_rollover->epoch;
        my $volsurface = Quant::Framework::VolSurface::Delta->new({
            underlying       => $underlying,
            creation_date    => $raw_volsurface->{creation_date},
            surface          => $raw_volsurface->{surface},
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        });

        if (defined $volsurface and $volsurface->is_valid and $self->passes_additional_check($volsurface)) {
            $volsurface->save;
            $self->report->{$symbol}->{success} = 1;
        } else {
            # don't produce noise in logs, when VS is identical to existing one, and recorded_date of existing is < 60 mins
            if (
                $quanto_only eq 'NO' && !(
                    $volsurface->validation_error =~ /identical to existing one/
                    && time - Quant::Framework::VolSurface::Delta->new({
                            underlying       => $underlying,
                            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
                        }
                    )->creation_date->epoch < 60 * 60

                ))
            {
                $self->report->{$symbol} = {
                    success => 0,
                    reason  => $volsurface->validation_error,
                };
            }
        }
    }
    $self->SUPER::run();
    return 1;
}

sub _append_to_existing_surface {
    my ($new_surface, $underlying_symbol) = @_;
    my $underlying = create_underlying($underlying_symbol);
    my $existing_surface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying})->surface;

    foreach my $term (keys %{$existing_surface}) {
        my $tenor = $existing_surface->{$term}->{tenor};
        next unless $tenor;
        next if $tenor eq 'ON' or $tenor eq '1W';
        $new_surface->{$tenor} = $existing_surface->{$term};
    }

    return $new_surface;

}

sub process_volsurface {
    my ($self, $data) = @_;

    my $vol_surface;
    foreach my $underlying_symbol (keys %$data) {

        if ($data->{$underlying_symbol}->{error}) {
            $self->report->{'frx' . $underlying_symbol} = {
                success => 0,
                reason  => $data->{$underlying_symbol}->{error},
            };
            next;
        }
        my ($surface_data, $rr_bf_flag, $error) = _get_surface_data($data->{$underlying_symbol});

        if ($error) {
            $self->report->{'frx' . $underlying_symbol} = {
                success => 0,
                reason  => $error,
            };
            next;
        }

        _do_flatten_ON($surface_data);

        $vol_surface->{'frx' . $underlying_symbol} = {
            surface       => $surface_data,
            type          => 'delta',
            creation_date => $data->{$underlying_symbol}->{volupdate_time},
            rr_bf_status  => $rr_bf_flag,
        };
    }

    return $vol_surface;
}

=head2 _do_flatten_ON
Will flatten the ON smile if the ON Butterfly point is negative. ie make the ON butterfly point to be zero.
=cut

sub _do_flatten_ON {
    my $surface_data = shift;

    if (   not exists $surface_data->{ON}
        or not exists $surface_data->{ON}->{smile}->{25}
        or not exists $surface_data->{ON}->{smile}->{75})
    {
        return;
    }

    my %raw = (
        '25D' => $surface_data->{ON}->{smile}->{25},
        '75D' => $surface_data->{ON}->{smile}->{75},
        'ATM' => $surface_data->{ON}->{smile}->{50},
    );

    my $RR = $raw{'25D'} - $raw{'75D'};
    my $BF = ($raw{'25D'} + $raw{'75D'}) / 2 - $raw{ATM};

    if ($BF < 0) {
        # these are the "delta from RR/BF" formulae, missing the BF
        # term since we are re-calculating with a BF of zero.
        $surface_data->{ON}->{smile} = {
            25 => ($raw{ATM} + 0.5 * $RR),
            50 => $raw{ATM},
            75 => ($raw{ATM} - 0.5 * $RR),
        };
    }

    return 1;
}

=head2 _get_surface_data
Mapping the vol spread and vol smile of each term
=cut

sub _get_surface_data {
    my ($data) = @_;
    my ($surface_vol, $rr_bf_flag, $error) = _process_smiles_spread($data);

    return ($surface_vol, $rr_bf_flag, $error) if defined $error;
    my %surface_data =
        map { $_ => {smile => $surface_vol->{$_}->{smile}, vol_spread => $surface_vol->{$_}->{vol_spread}} } keys %$surface_vol;

    return (\%surface_data, $rr_bf_flag, $error);
}

=head2 _process_smiles_spread
Return a hash reference that contains vol smile and vol spread of 3 delta points (25D, ATM and 75D).
Note:
Bloomberg construct the 25D call and 25D put from the mid price and applied a constant price spread to workout the bid and ask price of the call and put.The constant spread is taken from price spread of ATM straddle at the same maturity. Since we can not obtain the market price of the ATM straddle, we had done backtesting on these data points, we found that the ratio between these data points are quite constant.From our data analysis, we found 0.7 seems to be a fine constant.
=cut

sub _process_smiles_spread {
    my ($vol_surf) = @_;

    my ($rr_bf_flag, $error);
    ($vol_surf, $rr_bf_flag, $error) = _check_vol_point($vol_surf);

    return ($vol_surf, $rr_bf_flag, $error) if defined $error;
    my $surface_vol;
    foreach my $term (keys %{$vol_surf}) {
        next if $term eq 'volupdate_time';
        $surface_vol->{$term}->{smile}->{'50'} = $vol_surf->{$term}->{smile}->{'ATM'};
        if (scalar keys %{$vol_surf->{$term}->{smile}} == 1) {
            $surface_vol->{$term}->{smile}->{'25'} = $vol_surf->{$term}->{smile}->{'ATM'};
            $surface_vol->{$term}->{smile}->{'75'} = $vol_surf->{$term}->{smile}->{'ATM'};
        } else {
            $surface_vol->{$term}->{smile}->{'25'} =
                $vol_surf->{$term}->{smile}->{'ATM'} + $vol_surf->{$term}->{smile}->{'25RR'} / 2 + $vol_surf->{$term}->{smile}->{'25BF'};
            $surface_vol->{$term}->{smile}->{'75'} =
                $vol_surf->{$term}->{smile}->{'ATM'} - $vol_surf->{$term}->{smile}->{'25RR'} / 2 + $vol_surf->{$term}->{smile}->{'25BF'};
        }
        $surface_vol->{$term}->{vol_spread}->{'50'} = $vol_surf->{$term}->{spread}->{'ATM'};
        $surface_vol->{$term}->{vol_spread}->{'25'} = $vol_surf->{$term}->{spread}->{'ATM'} / 0.7;
        $surface_vol->{$term}->{vol_spread}->{'75'} = $vol_surf->{$term}->{spread}->{'ATM'} / 0.7;
    }

    return ($surface_vol, $rr_bf_flag, $error);
}

sub _check_vol_point {
    my ($vol_surf) = @_;
    my $rr_bf_flag = 0;
    foreach my $term (keys %{$vol_surf}) {
        next if $term eq 'volupdate_time';
        return ({}, 0, "Missing ATM vol for $term") if (not defined $vol_surf->{$term}->{smile}->{'ATM'});

        if (not defined $vol_surf->{$term}->{smile}->{'25RR'}) {
            $vol_surf->{$term}->{smile}->{'25RR'} = 0;
            $rr_bf_flag = 1;
        }
        if (not defined $vol_surf->{$term}->{smile}->{'25BF'}) {
            $vol_surf->{$term}->{smile}->{'25BF'} = 0;
            $rr_bf_flag = 1;
        }

    }

    return ($vol_surf, $rr_bf_flag, undef);
}

sub passes_additional_check {
    my ($self, $volsurface) = @_;

    # We don't want to save surfaces from after the Friday rollover to just before
    # the Monday open. effective_date->is_a_weekend works wonderfully as a check.
    # We also don't want to save after close on Friday (in the case that our close
    # comes before the rollover) as that causes us to cut the ON vol to zero (no
    # business hours to the new cut time).
    # More generally, we don't want to update if we won't trade on the effective date,
    # for the same reasons. This is likely mostly partially covered by some of the above,
    # but I am sitting here fixing this on Christmas, so I might be missing something.
    my $underlying         = create_underlying($volsurface->underlying->symbol);
    my $calendar           = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());
    my $creation_date      = $volsurface->creation_date;
    my $friday_after_close = ($creation_date->day_of_week == 5 and not $calendar->is_open_at($underlying->exchange, $creation_date));
    my $wont_open          = not $calendar->trades_on($underlying->exchange, $volsurface->effective_date);

    if (   $volsurface->effective_date->is_a_weekend
        or $friday_after_close
        or $wont_open)
    {
        $volsurface->validation_error('Not updating surface as it is the weekend or the underlying will not open.');
    }

    return !$volsurface->validation_error;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
