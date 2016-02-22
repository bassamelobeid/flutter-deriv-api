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
use BOM::Market::UnderlyingDB;
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
        : 'https://www.dropbox.com//www.dropbox.com/s/4tv8y7sph1nh0cb/auto_upload_stocks.xls?dl=0';
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
        @symbols_to_update = grep { not $skip_list{$_} and $_ !~ /^SYN/ } BOM::Market::UnderlyingDB->instance->get_symbols_for(
            market            => 'indices',
            contract_category => 'ANY',
            exclude_disabled  => 1
        );
        # forcing it here since we don't have offerings for the index.
        push @symbols_to_update, 'FTSE';

        # update vol of those plan to offer underlyings. This will be remove on yngshan/enable_stocks
        push @symbols_to_update, qw(IXIC NIFTY SHSZ300); 

    } else {
        @symbols_to_update = BOM::Market::UnderlyingDB->instance->get_symbols_for(
            market            => 'stocks',
            contract_category => 'ANY',
            exclude_disabled  => 1,
            submarket         => ['france', 'belgium', 'amsterdam']);
        # Update vol of those plan to offer underlyings. This will be remove on yngshan/enable_stocks
        push @symbols_to_update , qw(USAAPL USAMZN USCT USFB USGE USGOOG USKO USMSFT USPFE USXOM UKBARC UKBATS UKGSK UKHSBA UKVOD DEALV DEBAYN DEDAI DESIE DEVOW AUANZ AUBHP AUCBA AUMQG AUQAN IXIC);

   }

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
    my %valid_synthetic = map { $_ => 1 } BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => 'indices',
        submarket         => 'smart_index',
        contract_category => 'ANY',
        exclude_disabled  => 1
    );
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
            underlying     => $underlying,
            recorded_date  => $raw_volsurface->{recorded_date},
            spot_reference => $raw_volsurface->{spot_reference},
            surface        => $raw_volsurface->{surface},
        });
        if ($volsurface->is_valid) {
            if (exists $valid_synthetic{'SYN' . $volsurface->underlying->symbol}) {
                my $syn               = BOM::Market::Underlying->new('SYN' . $symbol);
                my $synthetic_surface = $volsurface->clone({
                    underlying => $syn,
                    cutoff     => $syn->exchange->closing_on($syn->exchange->representative_trading_date)->time_cutoff
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
