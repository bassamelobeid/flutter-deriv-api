package Runner::Superderivatives_EQ;

use Moose;

use lib ("/home/git/regentmarkets/bom/t/BOM/Product");
use List::Util qw(max sum min);
use File::Slurp;

use BOM::Product::ContractFactory qw( produce_contract );
use CSVParser::Superderivatives_EQ;

has suite => (
    is      => 'ro',
    isa     => 'Str',
    default => 'mini',
);

has files => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [qw(SX5E2 DJI FCHI SPC N225 SSECOMP FTSE)] },
);

has report_file => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            all      => '/tmp/sdeq_all_result_file.csv',
            analysis => '/tmp/sdeq_analysis_file.csv',
        };
    },
);

has 'csv_title' => (
    is      => 'ro',
    isa     => 'Str',
    default => "ID,underlying,bet_type,start_date,expiry_date,spot,barrier,barrier2,pricing_args_iv,sd_mid,bom_mid,mid_diff",
);

sub run_dataset {
    my $self = shift;

    write_file($self->report_file->{all}, $self->csv_title . "\n");
    my $path  = '/home/git/regentmarkets/bom-quant-benchmark/t/csv/superderivatives';
    my @files = @{$self->files};
    my @all_mid_diff;
    my ($all_results, $quanto_all_results);
    for my $symbol (@files) {
        my $file    = "$path/SD_$symbol.csv";
        my $records = CSVParser::Superderivatives_EQ->new(
            file  => $file,
            suite => $self->suite,
        )->records;
        my ($calculated_results, $quanto_results) = $self->price_superderivatives_bets_locally($records);
        foreach my $bettype (keys %$calculated_results) {
            push @{$all_results->{$bettype}}, @{$calculated_results->{$bettype}};
        }
        foreach my $bettype (keys %$quanto_results) {
            push @{$quanto_all_results->{$bettype}}, @{$quanto_results->{$bettype}} if $quanto_results;
        }

        #cool off period for couch to close some connections, for lack of other options.
        sleep(30);
    }

    my $benchmark_report;

    if (keys %$all_results) {
        my $analysis_report = $self->_calculate_analysis_report($all_results);
        $benchmark_report->{BASE} = $analysis_report;
    }
    if (keys %$quanto_all_results) {
        my $quanto_analysis_report = $self->_calculate_analysis_report($quanto_all_results);
        $benchmark_report->{QUANTO} = $quanto_analysis_report;
    }

    $self->_save_analysis($benchmark_report);
    return $benchmark_report;
}

sub _calculate_analysis_report {
    my ($self, $results) = @_;

    my $output;
    foreach my $bet_type (keys %{$results}) {
        my @records          = @{$results->{$bet_type}};
        my $number_of_record = scalar @records;
        $output->{$bet_type}->{avg} = sum(@records) / $number_of_record;
        $output->{$bet_type}->{max} = max(@records);
    }

    return $output;
}

sub _save_analysis {
    my ($self, $output) = @_;

    my $file = $self->report_file->{analysis};
    write_file($file, "SD EQ BREAKDOWN ANALYSIS\n\nBET_TYPE,AVG_MID_DIFF,MAX_MID_DIFF\n");

    foreach my $type (keys %$output) {
        append_file($file, "$type:\n");
        foreach my $bet_type (keys %{$output->{$type}}) {
            my $output_string = $bet_type . "," . $output->{$type}->{$bet_type}->{avg} . "," . $output->{$type}->{$bet_type}->{max} . "\n";
            append_file($file, $output_string);
        }
    }
}

sub price_superderivatives_bets_locally {
    my ($self, $records) = @_;

    my $breakdown = {};
    my $quanto    = {};
    my $i         = 0;
    foreach my $record (@$records) {
        my $bet = produce_contract({
            current_spot => $record->{spot},
            underlying   => $record->{underlying},
            barrier      => $record->{barrier},
            barrier2     => $record->{barrier2},
            bet_type     => $record->{bet_type},
            date_start   => $record->{date_start}->epoch + $record->{start_offset},
            date_expiry  => $record->{date_expiry}->epoch + $record->{expiry_offset},
            volsurface   => $record->{volsurface},
            payout       => $record->{payout},
            currency     => $record->{currency},
            date_pricing => $record->{date_start}->epoch + 9 * 3600,
        });
        my $bom_mid  = $bet->theo_probability->amount;
        my $sd_mid   = $record->{sd_mid};
        my $mid_diff = abs($sd_mid - $bom_mid);

        my $result =
              "$record->{ID},"
            . $record->{underlying}->symbol
            . ",$record->{bet_type},"
            . $record->{date_start}->epoch . ","
            . $record->{date_expiry}->epoch
            . ",$record->{spot},$record->{barrier},$record->{barrier2},"
            . $bet->pricing_args->{iv}
            . ",$sd_mid,$bom_mid,$mid_diff";

        append_file($self->report_file->{all}, $result . "\n");
        if ($bet->priced_with eq 'quanto') {
            push @{$quanto->{$record->{bet_type}}}, $mid_diff,;
        } else {
            push @{$breakdown->{$record->{bet_type}}}, $mid_diff;
        }
        $i++;
    }

    return ($breakdown, $quanto);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
