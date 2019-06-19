package BOM::MarketDataAutoUpdater::CryptoMonitor;

use Moose;
extends 'BOM::MarketDataAutoUpdater';

use Text::CSV::Slurp;
use Path::Tiny;

use BOM::Config::Chronicle;
use Date::Utility;
use Finance::Asset::Market::Registry;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData qw(create_underlying_db);
use BOM::Config::Runtime;
use Bloomberg::FileDownloader;
use Bloomberg::RequestFiles;
use Quant::Framework;
use BOM::Config::Chronicle;
use DataDog::DogStatsd::Helper qw(stats_gauge);

has file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_file {
    my $self  = shift;
    my @files = Bloomberg::FileDownloader->new->grab_files({
        file_type => 'ohlc',
    });
    return \@files;
}

sub run {
    my $self = shift;

    my @files  = @{$self->file};
    my $report = $self->report;
    if ($#files == -1) {
        push @{$report->{error}}, 'Crypto Monitor is terminating prematurely. File does not exist';
        return;
    }

    if ($#files > 1000) {
        push @{$report->{error}}, 'Crypto Monitor is terminating prematurely. Number of files in Bloomberg seems too big: [' . $#files . ']';
        return;
    }

    if ($#files != 0) {
        push @{$report->{error}}, 'Crypto Monitor is terminating prematurely. We only expect 1 single file';
        return;
    }

    my @symbols_to_update = qw/cryBTCUSD cryLTCUSD cryETHUSD/;

    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());

    my $file = $files[0];

    my @bloomberg_result_lines = path($file)->lines_utf8;

    if (not scalar @bloomberg_result_lines) {
        push @{$report->{error}}, "File[$file] is empty";
        next;
    }

    my %bloomberg_to_binary = Bloomberg::UnderlyingConfig::bloomberg_to_binary;
    my $csv = Text::CSV::Slurp->load(file => $file);

    foreach my $data (@$csv) {
        my $ohlc_data;

        next if ($data->{'ERROR CODE'} != 0 or grep { $_ eq 'N.A.' } values %$data);

        my $bb_symbol = $data->{SECURITIES};

        next unless $bb_symbol;

        my $bom_underlying_symbol = $bloomberg_to_binary{$bb_symbol};

        next if not(grep { $_ eq $bom_underlying_symbol } (@symbols_to_update));

        unless ($bom_underlying_symbol) {
            push @{$report->{error}}, "Unregconized bloomberg symbol[$bb_symbol]";
            next;
        }
        my $underlying = create_underlying($bom_underlying_symbol);

        my $symbol = $underlying->symbol;
        $ohlc_data->{item} = $symbol;
        my $date = $data->{LAST_UPDATE_DATE_EOD} ? $data->{LAST_UPDATE_DATE_EOD} : $data->{PX_YEST_DT};
        $date =~ s/^0//;

        my $ohlc_date = Date::Utility->new($date);
        next if (not $trading_calendar->trades_on($underlying->exchange, $ohlc_date));

        my $binary_closing_tick = $underlying->closing_tick_on($ohlc_date);
        next if not defined $binary_closing_tick;

        my $close = $data->{PX_LAST_EOD} ? $data->{PX_LAST_EOD} : $data->{PX_YEST_CLOSE};

        my $diff_pct = (($binary_closing_tick->quote - $close) / $close) * 100;

        #Add datadog monitoring code here
        stats_gauge('Crypto_OHLC_diff_percentage', $diff_pct, {tags => ['tag:' . $bom_underlying_symbol]});

    }

    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
