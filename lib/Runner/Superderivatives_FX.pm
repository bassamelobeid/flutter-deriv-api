package Runner::Superderivatives_FX;

use Moose;

use lib ("/home/git/regentmarkets/bom/t/BOM/Product");

use File::Slurp qw(append_file write_file);
use List::Util qw(sum max);
use Text::CSV;
use Carp;

use CSVParser::Superderivatives_FX;
use BOM::Product::ContractFactory qw( produce_contract );
use Date::Utility;

has suite => (
    is      => 'ro',
    isa     => 'Str',
    default => 'mini',
);

has files => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub {
        [qw(20111117_EURUSD 20111121_USDJPY 20111201_GBPJPY 20111201_USDSEK 20111202_USDCHF 20111203_GBPAUD 20111203_GBPPLN)];
    },
);

has report_file => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            all_base      => '/tmp/sdfx_base_result_file.csv',
            all_num       => '/tmp/sdfx_num_result_file.csv',
            analysis_num  => '/tmp/sdfx_num_analysis_file.csv',
            analysis_base => '/tmp/sdfx_base_analysis_file.csv',
        };
    },
);

sub run_dataset {
    my $self = shift;

    my @files = @{$self->files};
    my $result_all;

    my $csv_title =
        "ID,underlying,bet_type,spot,barrier,barrier2,duration(days),date_start,date_expiry,BOM_pricing_args_iv,SD_mid,BOM_mid,mid_diff,arbitrage_check_base";
    write_file($self->report_file->{all_base}, $csv_title . "\n");
    write_file($self->report_file->{all_num},  $csv_title . "\n");

    my $analysis_title = "BET_TYPE,AVG_MID_DIFF,MAX_MID_DIFF\n";
    write_file($self->report_file->{analysis_base}, $analysis_title);
    write_file($self->report_file->{analysis_num},  $analysis_title);

    my $base_results;
    my $num_results;

    foreach my $file (@files) {
        my $file_loc = '/home/git/regentmarkets/bom/t/BOM/Product/Benchmark/csv/superderivatives';
        my $file     = $file_loc . '/' . $file . '.csv';

        my $records = CSVParser::Superderivatives_FX->new(
            file  => $file,
            suite => $self->suite,
        )->records;

        my @base_dataset      = @{$records->{base_records}};
        my @numeraire_dataset = @{$records->{numeraire_records}};

        my $base      = $self->get_bet_results(\@base_dataset,      'base');
        my $numeraire = $self->get_bet_results(\@numeraire_dataset, 'numeraire');

        foreach my $bettype (keys %$base) {
            push @{$base_results->{$bettype}}, @{$base->{$bettype}};
        }
        foreach my $bettype (keys %$numeraire) {
            push @{$num_results->{$bettype}}, @{$numeraire->{$bettype}};
        }
    }

    my $base_analysis_report      = $self->calculates_and_saves_analysis_report($self->report_file->{analysis_base}, $base_results);
    my $numeraire_analysis_report = $self->calculates_and_saves_analysis_report($self->report_file->{analysis_num},  $num_results);

    return {
        NUM  => $numeraire_analysis_report,
        BASE => $base_analysis_report,
    };
}

sub calculates_and_saves_analysis_report {
    my ($self, $file, $results) = @_;

    my $analysis_results;
    foreach my $bet_type (keys %$results) {
        my @mid_diffs = @{$results->{$bet_type}};
        my $avg       = sum(@mid_diffs) / scalar(@mid_diffs);
        my $max       = max(@mid_diffs);
        $analysis_results->{$bet_type}->{avg} = $avg;
        $analysis_results->{$bet_type}->{max} = $max;
        append_file($file, "$bet_type,$avg,$max\n");
    }

    return $analysis_results;
}

sub get_bet_results {
    my ($self, $records, $base_or_num) = @_;

    my $csv = Text::CSV->new();
    my $analysis_results;
    foreach my $record (@$records) {
        my $date_start   = $record->{date_start};
        my $date_expiry  = $record->{date_expiry};
        my $underlying   = $record->{underlying};
        my $surface      = $record->{volsurface};
        my $payout       = $record->{payout};
        my $date_pricing = $record->{date_start};
        my $spot         = $record->{spot};
        my $days_between = $date_expiry->days_between($date_start);

        next if $date_expiry->epoch - $date_start->epoch > 365 * 86400;
        next if $date_expiry->is_a_weekend or $date_start->is_a_weekend;

        my $barrier  = $record->{barrier};
        my $barrier2 = $record->{barrier2};
        my $currency = ($base_or_num eq 'base') ? $record->{base_currency} : $record->{numeraire_currency};
        my $bet_type = $record->{bet_type};

        my $bet = produce_contract({
            underlying   => $underlying,
            barrier      => $barrier,
            barrier2     => $barrier2,
            bet_type     => $bet_type,
            date_start   => $date_start,
            date_expiry  => $date_expiry,
            volsurface   => $surface,
            payout       => $payout,
            currency     => $currency,
            date_pricing => $date_start,
            current_spot => $spot,
        });

        my $bom_mid = $bet->theo_probability->amount;
        my $bom_bs  = $bet->bs_probability->amount;
        my $sd_mid  = $record->{sd_mid};

        next if $sd_mid < 0.05 or $sd_mid > 0.95;

        my $sd_bid = $record->{sd_bid};
        my $sd_ask = $record->{sd_ask};

        my $mid_diff = abs($sd_mid - $bom_mid);

        my $arbitrage_check = ($bet->bid_probability->amount > $sd_ask or $bet->ask_probability->amount < $sd_bid) ? 1 : 0;

        $csv->combine(
            $record->{ID}, $underlying->symbol, $bet_type,                 $spot,              $barrier,
            $barrier2,     $days_between,       $date_start->date_ddmmmyy, $date_expiry->date, $bet->pricing_args->{iv},
            $sd_mid,       $bom_mid,            $mid_diff,                 $arbitrage_check
        );
        my $result = $csv->string;

        append_file($self->report_file->{all_base}, "$result\n");
        push @{$analysis_results->{$bet_type}}, $mid_diff;
    }

    return $analysis_results;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
