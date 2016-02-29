package BOM::MarketData::AutoUpdater::Forex;

=head1 NAME

BOM::MarketData::AutoUpdater::Forex

=head1 DESCRIPTION

Auto-updates Forex vols.

=cut

use Moose;
extends 'BOM::MarketData::AutoUpdater';

use Bloomberg::FileDownloader;
use Bloomberg::VolSurfaces;
use BOM::Platform::Runtime;
use BOM::Market::UnderlyingDB;
use Date::Utility;
use Try::Tiny;
use File::Find::Rule;
use BOM::Market::Underlying;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::VolSurface::Delta;
use List::Util qw( first );
has file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_file {
    my $self = shift;

    my $now = Date::Utility->new;
    my $loc = '/feed/BBDL';
    my $on  = Date::Utility->new($now->epoch);

    while (not -d $loc . '/' . $on->date_yyyymmdd) {
        $on = Date::Utility->new($on->epoch - 86400);
        if ($on->year <= 2011) {
            $self->_logger->logcroak('Requested date pre-dates vol surface history.');
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

    #  On weekend, we only subscribe the volsurface file at 23:40GMT. So anytime before this, there is no file available
    # On weekday, the first response file of the day is at 00:45GMT, hence at the first 45 minutes of the day, there is no file
    if (not $file and $now->hour > 0 and $now->is_a_weekday) {

        die('Could not find volatility source file for time[' . $now->datetime . ']');
    }
    my $quanto_file = $now->is_a_weekday ? $loc . '/' . $day . '/quantovol.csv' : $loc . '/' . $day . '/quantovol_wknd.csv';

    my @files = $file ? ($file, $quanto_file) : ($quanto_file);
    return \@files;
}

has symbols_to_update => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_symbols_to_update {
    my @forex = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => ['forex'],
        submarket         => ['major_pairs', 'minor_pairs'],
        contract_category => 'ANY',
        broker            => 'VRT',
    );
    my @commodities = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => 'commodities',
        contract_category => 'ANY',
        broker            => 'VRT',
    );

    my @quanto_currencies = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market      => ['forex', 'commodities',],
        quanto_only => 1,
    );
    my %skip_list =
        map { $_ => 1 } (
        @{BOM::Platform::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol},
        qw(frxBROUSD frxBROAUD frxBROEUR frxBROGBP frxXPTAUD frxXPDAUD frxAUDSAR)
        );

    my @symbols = grep { !$skip_list{$_} } (@forex, @commodities, @quanto_currencies);

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
        my $surface = Bloomberg::VolSurfaces->new->parse_data_for($file);
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
    my @quanto_currencies = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market      => ['forex', 'commodities',],
        quanto_only => 1,
    );

    $self->_logger->debug(ref($self) . ' starting update.');
    my $surfaces_from_file = $self->surfaces_from_file;
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
        my $underlying = BOM::Market::Underlying->new($symbol);
        next if $underlying->volatility_surface_type eq 'flat';
        my $raw_volsurface = $surfaces_from_file->{$symbol};
        my $volsurface     = BOM::MarketData::VolSurface::Delta->new({
            underlying    => $underlying,
            recorded_date => $raw_volsurface->{recorded_date},
            surface       => $raw_volsurface->{surface},
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

    $self->_logger->debug(ref($self) . ' update complete.');
    $self->SUPER::run();
    return 1;
}

sub _append_to_existing_surface {
    my ($new_surface, $underlying_symbol) = @_;
    my $underlying       = BOM::Market::Underlying->new($underlying_symbol);
    my $existing_surface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({
            underlying => $underlying,
            cutoff     => 'New York 10:00'
        })->surface;

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
    my $underlying         = $volsurface->underlying;
    my $recorded_date      = $volsurface->recorded_date;
    my $friday_after_close = ($recorded_date->day_of_week == 5 and not $underlying->exchange->is_open_at($recorded_date));
    my $wont_open          = not $underlying->exchange->trades_on($volsurface->effective_date);

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
