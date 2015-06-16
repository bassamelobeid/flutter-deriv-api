package BOM::MarketData::AutoUpdater::Indices;

=head1 NAME

BOM::MarketData::AutoUpdater::Indices

=head1 DESCRIPTION

Updates Index vols from a given .file file.

=cut

use Moose;
extends 'BOM::MarketData::AutoUpdater';

use BOM::Market::Underlying;
use BOM::Platform::Runtime;
use BOM::Product::Offerings qw/get_offerings_with_filter/;
use SuperDerivatives::VolSurface;
use Try::Tiny;
use File::Temp;
use BOM::MarketData::VolSurface::Moneyness;

has filename => (
    is => 'ro',
);

has input_market => (
    is => 'ro',
);

has file => (
    is         => 'ro',
    lazy_build => 1,
);

has uses_binary_spot => (
    is      => 'ro',
    default => sub {
        {
            STI      => 1,
            SZSECOMP => 1,
        };
    },
);

sub _build_file {
    my $self     = shift;
    my $filename = $self->filename;
    my $url =
        $filename eq 'auto_upload.xls'
        ? 'https://www.dropbox.com/s/67s60tryh057qx1/auto_upload.xls?dl=0'
        : 'https://www.dropbox.com//www.dropbox.com/s/4tv8y7sph1nh0cb/auto_upload_Euronext.xls?dl=0';
    my $file = '/tmp/' . $filename;
    `wget -O $file $url > /dev/null 2>&1`;
    return $file;
}
has symbols_to_update => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_symbols_to_update {
    my $self      = shift;
    my $market    = $self->input_market;
    my %skip_list = map { $_ => 1 } (
        @{BOM::Platform::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol},
        qw(OMXS30 USAAPL USGOOG USMSFT USORCL USQCOM USQQQQ)
    );

    my @symbols_to_update;
    if ($market eq 'indices') {
        @symbols_to_update = grep { not $skip_list{$_} and $_ !~ /^SYN/ } get_offerings_with_filter('underlying_symbol', {market => 'indices'});
    } else {
        @symbols_to_update = get_offerings_with_filter(
            'underlying_symbol',
            {
                market    => 'stocks',
                submarket => ['france', 'belgium', 'amsterdam']});
    }
    push @symbols_to_update, "FTSE";
    return \@symbols_to_update;
}

has surfaces_from_file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_surfaces_from_file {
    my $self = shift;
    return SuperDerivatives::VolSurface->new->parse_data_for($self->file, $self->symbols_to_update);
}

sub run {
    my $self = shift;
    $self->_logger->debug(ref($self) . ' starting update.');
    my $surfaces_from_file = $self->surfaces_from_file;
    my %valid_synthetic = map { $_ => 1 } get_offerings_with_filter('underlying_symbol', {submarket => 'smart_index'});
    foreach my $symbol (@{$self->symbols_to_update}) {
        if (not $valid_synthetic{$symbol} and not $surfaces_from_file->{$symbol}) {
            $self->report->{$symbol} = {
                success => 0,
                reason  => 'Surface Information missing from datasource for ' . $symbol,
            };
            next;
        }
        my $underlying     = BOM::Market::Underlying->new($symbol);
        my $raw_volsurface = $surfaces_from_file->{$symbol};
        if ($self->uses_binary_spot->{$symbol}) {
            $raw_volsurface->{spot_reference} = $underlying->tick_at($raw_volsurface->{recorded_date}->epoch, {allow_inconsistent => 1})->quote;
        }
        my $volsurface = BOM::MarketData::VolSurface::Moneyness->new({
            underlying    => $underlying,
            recorded_date => $raw_volsurface->{recorded_date},
            spot_refence  => $raw_volsurface->{spot_reference},
            surface       => $raw_volsurface->{surface},
        });
        if ($volsurface->is_valid) {
            if (exists $valid_synthetic{'SYN' . $volsurface->underlying->symbol}) {
                my $syn               = BOM::Market::Underlying->new('SYN' . $symbol);
                my $synthetic_surface = $volsurface->clone({
                    underlying => $syn,
                    cutoff     => $syn->exchange->closing_on($underlying->exchange->representative_trading_date)->time_cutoff
                });
                $synthetic_surface->save;
            }
            $volsurface->save;
            $self->report->{$symbol}->{success} = 1;
        } else {
            $self->report->{$symbol} = {
                success => 0,
                reason  => $volsurface->validation_error,
            };
        }
    }

    $self->_logger->debug(ref($self) . ' update complete.');
    $self->SUPER::run();
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
