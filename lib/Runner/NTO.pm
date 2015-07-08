package Runner::NTO;

use Moose;
use lib qw(/home/git/regentmarkets/bom/t/BOM/Product);
use BOM::Product::ContractFactory qw( produce_contract );
use CSVParser::NTO;
use Format::Util::Numbers qw(roundnear);

use Test::MockModule;
use List::Util qw(max sum);
use File::Slurp qw(append_file write_file);
use Text::CSV::Slurp;
use Carp;

has _report_file => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            all      => '/tmp/nto_full_result.csv',
            analysis => '/tmp/nto_analysis_result.csv',
        };
    },
);

sub run_dataset {
    my $self = shift;

    my $nto_csv = '/home/git/regentmarkets/bom-quant-benchmark/t/csv/nto/NextTopOption.csv';
    my $parser  = CSVParser::NTO->new(
        nto_csv => $nto_csv,
    );
    my $report = $self->_calculate_results($parser);
    return $report;
}

sub _calculate_results {
    my ($self, $parser) = @_;

    $self->_save_full_result_header;

    my $full_report_file = $self->_report_file->{all};
    my @output;
    my $analysis_profit_diffs;

    foreach my $record (@{$parser->records}) {
        my $bet_args = _get_bet_args($record);

        my $mock = Test::MockModule->new('BOM::Market::Underlying');
        $mock->mock('interest_rate_for', sub { return 0 });
        $mock->mock('dividend_rate_for', sub { return 0 });
        my $bet               = produce_contract($bet_args);
        my $bom_return        = 100 * roundnear(1 / 10000, ($bet->payout - $bet->ask_price) / $bet->ask_price) . "%";
        my $bom_client_profit = $record->{nto_win} ? $record->{payout} - $bet->ask_price : -1 * $bet->ask_price;
        my $profit_diff       = $bom_client_profit - $record->{nto_client_profit};
        my $bet_type          = $bet->bet_type->code;

        my @output_array = (
            $record->{bet_num},                  $record->{currency},          $record->{underlying}, $bet_type,
            $record->{date_start}->date_ddmmmyy, $record->{date_expiry}->date, $bet->current_spot,    $bet->barrier->as_absolute,
            $bet->timeindays->amount * 24 * 60,  $record->{payout},            $bom_return,           $record->{nto_return},
            $bet->ask_price,                     $record->{nto_buy_price},     $bom_client_profit,    $record->{nto_client_profit},
            $profit_diff,
        );

        my $string = join ',', @output_array;
        $string .= "\n";

        append_file($full_report_file, $string);
        push @output, \@output_array;
        push @{$analysis_profit_diffs->{$bet_type}}, $profit_diff;
    }

    my $analysis_result = $self->_generates_and_saves_analysis_report($analysis_profit_diffs);

    return $analysis_result;
}

sub _get_bet_args {
    my $record = shift;

    my $underlying = (not ref $record->{underlying}) ? BOM::Market::Underlying->new($record->{underlying}) : $record->{underlying};
    my $fake_volsurface = BOM::MarketData::VolSurface::Delta->new(
        underlying => $underlying,
        surface    => {
            7 => {
                smile => {
                    50 => 0.2,
                    75 => 0.19,
                    25 => 0.21
                }
            },
            14 => {
                smile => {
                    50 => 0.3,
                    75 => 0.29,
                    25 => 0.32
                }}
        },
        recorded_date => Date::Utility->new,
    );

    return {
        underlying   => $underlying,
        bet_type     => $record->{bet_type},
        date_start   => $record->{date_start},
        date_expiry  => $record->{date_expiry},
        payout       => $record->{payout},
        currency     => $record->{currency},
        date_pricing => $record->{date_start},
        volsurface   => $fake_volsurface,
        rho          => {fd_dq => 0},
    };
}

sub _generates_and_saves_analysis_report {
    my ($self, $profit_diffs) = @_;
    my $file = $self->_report_file->{'analysis'};
    write_file($file, "\n");

    my $analysis_result;

    append_file($file, 'ANALYSIS REPORT:' . "\n\n" . 'BET_TYPE,AVG_PROFIT,SUM_PROFIT' . "\n");
    foreach my $bet_type (keys %{$profit_diffs}) {
        my @diff = @{$profit_diffs->{$bet_type}};
        my $avg  = sum(@diff) / scalar(@diff);
        my $sum  = sum(@diff);
        $analysis_result->{$bet_type}->{avg} = $avg;
        $analysis_result->{$bet_type}->{sum} = $sum;
        append_file($file, "$bet_type,$avg,$sum\n");
    }

    append_file($file, "\n\n");
    return $analysis_result;
}

sub _save_full_result_header {
    my $self        = shift;
    my $output_file = $self->_report_file->{all};
    my $csv_title   = join ',', qw(
        bet_num currency underlying bet_type date_start date_expiry S barrier duration payout
        bom_return nto_return bom_buy_price nto_buy_price bom_client_profit nto_client_profit client_profit_diff
    );

    write_file($output_file, "$csv_title\n");
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
