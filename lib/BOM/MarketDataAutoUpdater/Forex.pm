package BOM::MarketDataAutoUpdater::Forex;

=head1 NAME

BOM::MarketDataAutoUpdater::Forex

=head1 DESCRIPTION

Auto-updates Forex vols.

=cut

use Moose;
extends 'BOM::MarketDataAutoUpdater';

use Bloomberg::FileDownloader;
use Bloomberg::VolSurfaces;
use BOM::Platform::Runtime;
use Date::Utility;
use Try::Tiny;
use File::Find::Rule;
use BOM::MarketData qw(create_underlying create_underlying_db);
use BOM::MarketData::Types;
use BOM::MarketData::Fetcher::VolSurface;
use Quant::Framework::VolSurface::Delta;
use Quant::Framework::VolSurface::Utils qw(NY1700_rollover_date_on);
use List::Util qw( first );
use Quant::Framework;
use BOM::Platform::Chronicle;
use VolSurface::IntradayFX;

has file => (
    is         => 'ro',
    lazy_build => 1,
);

has tenor_file => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_file {
    my $self = shift;

    my $now          = Date::Utility->new;
    my $loc          = '/feed/BBDL';
    my $on           = Date::Utility->new($now->epoch);
    my $previous_day = $on->minus_time_interval('1d')->date_yyyymmdd;
    while (not -d $loc . '/' . $on->date_yyyymmdd) {
        $on = Date::Utility->new($on->epoch - 86400);
        if ($on->year <= 2011) {
            die('Requested date pre-dates vol surface history.');
        }
    }
    my $day                 = $on->date_yyyymmdd;
    my @filenames           = sort { $b cmp $a } File::Find::Rule->file()->name('*.csv')->in($loc . '/' . $day);
    my @non_quanto_filename = grep { $_ !~ /quantovol/ and $_ !~ /tenors/ } @filenames;
    my $file                = first {
        my ($h, $m, $s) = ($_ =~ /(\d{2})(\d{2})(\d{2})_vol_points\.csv$/);
        my $date = Date::Utility->new("$day $h:$m:$s");
        return $date->epoch <= $now->epoch;
    }
    @non_quanto_filename;

    my @tenor_filenames = grep { $_ =~ /tenors/ } @filenames;
    my $tenor_file = first {
        my ($h, $m, $s) = ($_ =~ /(\d{2})(\d{2})(\d{2})_vol_tenors\.csv$/);
        my $date = Date::Utility->new("$day $h:$m:$s");
        return $date->epoch <= $now->epoch;
    }
    @tenor_filenames;

    $self->tenor_file($tenor_file);

    #  On weekend, we only subscribe the volsurface file at 23:40GMT. So anytime before this, there is no file available
    # On weekday, the first response file of the day is at 00:45GMT, hence at the first 45 minutes of the day, there is no file
    if (not $file and $now->hour > 0 and $now->is_a_weekday) {

        die('Could not find volatility source file for time[' . $now->datetime . ']');
    }

    my $quanto_file;
    my $quanto_weekday_file = $loc . '/' . $day . '/quantovol.csv';
    my $quanto_weekend_file = $loc . '/' . $day . '/quantovol_wknd.csv';
    if ($now->is_a_weekday) {
        $quanto_file =
              (-e $quanto_weekday_file) ? $quanto_weekday_file
            : ($now->day_of_week == 1 and $now->hour == 0) ? $loc . '/' . $previous_day . '/quantovol_wknd.csv'
            :                                                $loc . '/' . $previous_day . '/quantovol.csv';
    } else {
        $quanto_file = (-e $quanto_weekend_file) ? $quanto_weekend_file : $loc . '/' . $previous_day . '/quantovol.csv';

    }
    my @files = $file ? ($file, $quanto_file) : ($quanto_file);
    return \@files;
}

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
        @{BOM::Platform::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol},
        qw(frxBROUSD frxBROAUD frxBROEUR frxBROGBP frxXPTAUD frxXPDAUD frxAUDSAR)
        );
    my @symbols =
        (grep { $_ =~ /vol_points/ } (@{$self->file}))
        ? grep { !$skip_list{$_} } (@forex, @commodities, @quanto_currencies)
        : grep { !$skip_list{$_} } (@quanto_currencies);
    return \@symbols;
}

has surfaces_from_file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_surfaces_from_file {
    my $self = shift;
    my @volsurface;
    foreach my $file (@{$self->file}) {
        my $surface;
        if ($file =~ /vol_points/) {
            $surface = Bloomberg::VolSurfaces->new->parse_data_for($file, $self->tenor_file);
        } else {
            $surface = Bloomberg::VolSurfaces->new->parse_data_for($file);
        }
        foreach my $underlying (keys %{$surface}) {
            if (scalar keys %{$surface->{$underlying}->{surface}} == 2) {
                $surface->{$underlying}->{surface} = _append_to_existing_surface($surface->{$underlying}->{surface}, $underlying);
            }
        }
        push @volsurface, $surface;
    }

    my $combined = {map { %$_ } @volsurface};
    return $combined;
}

has _connect_ftp => (
    is      => 'ro',
    default => 1,
);

=head1 METHODS

=head2 run

=cut

sub run {
    my $self = shift;

    Bloomberg::FileDownloader->new->grab_files({file_type => 'vols'}) if $self->_connect_ftp;
    my @quanto_currencies = create_underlying_db->get_symbols_for(
        market      => ['forex', 'commodities',],
        quanto_only => 1,
    );

    my $rollover_date           = NY1700_rollover_date_on(Date::Utility->new);
    my $one_hour_after_rollover = $rollover_date->plus_time_interval('1h');
    my $surfaces_from_file      = $self->surfaces_from_file;
    foreach my $symbol (@{$self->symbols_to_update}) {
        my $quanto_only = 'NO';
        if (grep { $_ eq $symbol } (@quanto_currencies)) {
            $quanto_only = "YES";
        }
        if (not $surfaces_from_file->{$symbol} and $quanto_only eq 'NO') {
            $self->report->{$symbol} = {
                success => 0,
                reason  => "Surface Information missing from datasource for $symbol. ",
            };
            next;
        }
        my $underlying = create_underlying($symbol);
        # Forex contracts with flat smiles are updated with a different module (MarketDataAutoUpdater/Flat.pm)
        next if $underlying->flat_smile;
        my $raw_volsurface = $surfaces_from_file->{$symbol};

        unless (exists $raw_volsurface->{recorded_date}) {
            warn "Volatility Surface data missing from provider for " . $underlying->symbol;
            next;    # skipping it here else it will die in the next line.
        }

        next
            if $raw_volsurface->{recorded_date}->epoch >= $rollover_date->epoch
            and $raw_volsurface->{recorded_date}->epoch <= $one_hour_after_rollover->epoch;
        my $volsurface = Quant::Framework::VolSurface::Delta->new({
            underlying       => $underlying,
            recorded_date    => $raw_volsurface->{recorded_date},
            surface          => $raw_volsurface->{surface},
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        });

        if (defined $volsurface and $volsurface->is_valid and $self->passes_additional_check($volsurface)) {
            $volsurface->save;
            $self->report->{$symbol}->{success} = 1;
        } else {
            if ($quanto_only eq 'NO') {
                $self->report->{$symbol} = {
                    success => 0,
                    reason  => $volsurface->validation_error,
                };
            }
        }
    }
    $self->warmup_intradayfx_cache();
    $self->SUPER::run();
    return 1;
}

sub _append_to_existing_surface {
    my ($new_surface, $underlying_symbol) = @_;
    my $underlying = create_underlying($underlying_symbol);
    my $existing_surface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying})->surface;

    foreach my $term (keys %{$existing_surface}) {

        my $tenor = $existing_surface->{$term}->{tenor};

        if ($tenor ne 'ON' and $tenor ne '1W') {
            $new_surface->{$tenor} = $existing_surface->{$term};
        }
    }

    return $new_surface;

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
    my $calendar           = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader());
    my $recorded_date      = $volsurface->recorded_date;
    my $friday_after_close = ($recorded_date->day_of_week == 5 and not $calendar->is_open_at($underlying->exchange, $recorded_date));
    my $wont_open          = not $calendar->trades_on($underlying->exchange, $volsurface->effective_date);

    if (   $volsurface->effective_date->is_a_weekend
        or $friday_after_close
        or $wont_open)
    {
        $volsurface->validation_error('Not updating surface as it is the weekend or the underlying will not open.');
    }

    return !$volsurface->validation_error;
}

sub warmup_intradayfx_cache {
    my $self = shift;

    foreach my $symbol (create_underlying_db->symbols_for_intradayfx) {
        my $cr = BOM::Platform::Chronicle::get_chronicle_reader(1);
        my $cw = BOM::Platform::Chronicle::get_chronicle_writer();
        my $u  = create_underlying($symbol);
        try {
            my $vs = VolSurface::IntradayFX->new(
                underlying       => $u,
                chronicle_reader => $cr,
                chronicle_writer => $cw,
                warmup_cache     => 1,
            );
            $vs->get_volatility({
                from => time,
                to   => time + 900,
            });
            $vs->get_volatility({
                    from                          => time,
                    to                            => time + 900,
                    include_economic_event_impact => 1,

            });
        }
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
