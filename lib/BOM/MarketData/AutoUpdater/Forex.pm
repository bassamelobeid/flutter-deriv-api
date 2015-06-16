package BOM::MarketData::AutoUpdater::Forex;

=head1 NAME

BOM::MarketData::AutoUpdater::Forex

=head1 DESCRIPTION

Auto-updates Forex vols.

=cut

use Moose;
extends 'BOM::MarketData::AutoUpdater';

use BOM::MarketData::Parser::Bloomberg::FileDownloader;
use BOM::MarketData::Parser::Bloomberg::VolSurfaces;
use BOM::Platform::Runtime;
use BOM::Market::UnderlyingDB;
use Date::Utility;
use Try::Tiny;
use File::Find::Rule;
use List::Util qw( first );
has file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_file {
    my $self = shift;

    my $now = Date::Utility->new;
    my $loc = BOM::Platform::Runtime->instance->app_config->system->directory->db . '/BBDL/' . $self->source;
    my $on  = Date::Utility->new($now->epoch);

    while (not -d $loc . '/' . $on->date_yyyymmdd) {
        $on = Date::Utility->new($on->epoch - 86400);
        if ($on->year <= 2011) {
            $self->_logger->logcroak('Requested date pre-dates vol surface history.');
        }
    }
    my $day                 = $on->date_yyyymmdd;
    my @filenames           = sort { $b cmp $a } File::Find::Rule->file()->name('*.csv')->in($loc . '/' . $day);
    my @non_quanto_filename = grep { $_ !~ /quantovol/ } @filenames;

    my $file = first {
        my ($h, $m, $s) = ($_ =~ /(\d{2})(\d{2})(\d{2})_?(OVDV|vol_points)?\.csv$/);
        my $date = Date::Utility->new("$day $h:$m:$s");
        return $date->epoch <= $now->epoch;
    }
    @non_quanto_filename;

    die('Could not find volatility source file for time[' . $now->datetime . ']') unless $file;
    my $quanto_file = $loc . '/' . $day . '/quantovol.csv';

    my @files = ($file, $quanto_file);

    return \@files;
}

has source => (
    is      => 'ro',
    default => BOM::Platform::Runtime->instance->app_config->quants->market_data->volatility_source,
);

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
        qw(frxBROUSD frxBROAUD frxBROEUR frxBROGBP frxXPTAUD frxXPDAUD)
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
        push @volsurface, BOM::MarketData::Parser::Bloomberg::VolSurfaces->new->parse_data_for($file, $self->source);
    }
    my $combined = {%{$volsurface[0]}, %{$volsurface[1]}};
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

    BOM::MarketData::Parser::Bloomberg::FileDownloader->new->grab_files({file_type => 'vols'}) if $self->_connect_ftp;
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
        my $volsurface = $surfaces_from_file->{$symbol};
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
