package Runner::Superderivatives_EQ;

use Moose;

use lib ("/home/git/regentmarkets/bom/t/BOM/Product");
use List::Util qw(max sum min);
use File::Slurp;
use Text::CSV;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use CSVParser::Superderivatives_EQ;
use Test::MockModule;

has suite => (
    is      => 'ro',
    isa     => 'Str',
    default => 'mini',
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
    my $file = shift;

    my @files = $file ? ($file) : ('DJI', 'FCHI', 'SPC', 'N225', 'SSECOMP', 'FTSE');

    write_file($self->report_file->{all}, $self->csv_title . "\n");
    my $path = '/home/git/regentmarkets/bom-quant-benchmark/t/csv/superderivatives';
    my $all_results;
    for my $symbol (@files) {
        my $file_path = "$path/SD_$symbol.csv";
        my $records   = CSVParser::Superderivatives_EQ->new(
            file  => $file_path,
            suite => $self->suite,
        )->records;
        my ($calculated_results) = $self->price_superderivatives_bets_locally($records);
        foreach my $bettype (keys %$calculated_results) {
            push @{$all_results->{$bettype}}, @{$calculated_results->{$bettype}};
        }
    }
    my $benchmark_report;
    my $analysis_report = $self->_calculate_and_saves_analysis_report($all_results);

    my $key = (scalar @files == 1) ? $file : 'BASE';
    $benchmark_report->{$key} = $analysis_report;
    return $benchmark_report;
}

sub _calculate_and_saves_analysis_report {
    my ($self, $results) = @_;

    my $file = $self->report_file->{analysis};
    write_file($file, "SD EQ BREAKDOWN ANALYSIS\n\nBET_TYPE,AVG_MID_DIFF,MAX_MID_DIFF\n");

    my $analysis_results;
    foreach my $bet_type (keys %{$results}) {
        my @records          = @{$results->{$bet_type}};
        my $number_of_record = scalar @records;
        my $avg              = sum(@records) / $number_of_record;
        my $max              = max(@records);
        $analysis_results->{$bet_type}->{avg} = $avg;
        $analysis_results->{$bet_type}->{max} = $max;
        my $output_string = $bet_type . "," . $avg . "," . $max . "\n";
        append_file($file, $output_string);
    }
    return $analysis_results;
}

sub price_superderivatives_bets_locally {
    my ($self, $records) = @_;
    my $csv       = Text::CSV->new();
    my $breakdown = {};
    my $i         = 0;
    # some underlying we do not offer anymore but the tests still have it
    my $mock = Test::MockModule->new('BOM::Product::ContractFactory');
    $mock->mock('_validate_input_parameters', sub {});

    my $module = Test::MockModule->new('Quant::Framework::VolSurface::Moneyness');
    my $spot_reference = 0;
    $module->mock('spot_reference', sub { return $spot_reference; });

    foreach my $record (@$records) {
        my $bet_args = {
            current_spot => $record->{spot},
            underlying   => $record->{underlying},
            bet_type     => $record->{bet_type},
            date_start   => $record->{date_start}->epoch + $record->{start_offset},
            date_expiry  => $record->{date_expiry}->epoch + $record->{expiry_offset},
            volsurface   => $record->{volsurface},
            payout       => $record->{payout},
            currency     => $record->{currency},
            date_pricing => $record->{date_start}->epoch + 9 * 3600,
            uses_empirical_volatility => 0,
        };
        $spot_reference = $record->{volsurface}->{spot_reference};

        if ($record->{barrier2}) {
            $bet_args->{low_barrier}  = $record->{barrier2};
            $bet_args->{high_barrier} = $record->{barrier};
        } else {
            $bet_args->{barrier} = $record->{barrier};
        }
        $bet_args->{current_tick} = Postgres::FeedDB::Spot::Tick->new(
            underlying => $bet_args->{underlying}->symbol,
            quote      => $bet_args->{current_spot},
            epoch      => $bet_args->{date_start},
        );

        my $bet = produce_contract($bet_args);

        my $base_prob = $bet->pricing_engine->can('_base_probability') ? $bet->pricing_engine->_base_probability : $bet->pricing_engine->base_probability;
        $base_prob = $base_prob->amount if ref $base_prob;

        my $bom_mid  = $base_prob;
        my $sd_mid   = $record->{sd_mid};
        my $mid_diff = abs($sd_mid - $bom_mid);
        my @barriers = $bet->two_barriers ? ($bet->high_barrier->as_absolute, $bet->low_barrier->as_absolute) : ($bet->barrier->as_absolute, 'NA');

        $csv->combine(
            $record->{ID},                 $record->{underlying}->symbol, $record->{bet_type}, $record->{date_start}->epoch,
            $record->{date_expiry}->epoch, $record->{spot},               @barriers,           $bet->_pricing_args->{iv},
            $sd_mid,                       $bom_mid,                      $mid_diff
        );

        my $result = $csv->string;
        append_file($self->report_file->{all}, $result . "\n");
        push @{$breakdown->{$record->{bet_type}}}, $mid_diff;
        $i++;
    }

    return ($breakdown);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
