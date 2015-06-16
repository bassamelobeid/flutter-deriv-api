package Benchmark::Runner::Merlin;

use Moose;
use lib qw(/home/git/bom/t/BOM/Product);
use Date::Utility;
use BOM::Market::Data::Tick;
use BOM::Market::Underlying;
use BOM::Product::ContractFactory qw( produce_contract );
use Benchmark::CSVParser::Merlin;

use List::Util qw(max sum);
use File::Slurp qw(append_file write_file);
use Text::CSV::Slurp;
use Carp;

has suite => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has _expiry => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            '15TK' => {
                local => 'Tokyo 15:00',
                bom   => '06:00:00'
            },
            '10NY' => {
                local => 'New York 10:00',
                bom   => '14:00:00'
            },
        };
    },
);

has _mapper => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            DIGITALCALL           => 'CALL',
            DIGITALPUT            => 'PUT',
            DOUBLENOTOUCH         => 'RANGE',
            NOTOUCH               => 'NOTOUCH',
            DOUBLEONETOUCHINSTANT => 'UPORDOWN',
            ONETOUCHINSTANT       => 'ONETOUCH',
        };
    },
);

has _report_file => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            all      => '/tmp/merlin_full_result.csv',
            analysis => '/tmp/merlin_analysis_result.csv',
        };
    },
);

has run_only => (
    is      => 'ro',
    isa     => 'Str',
    default => '1-15135',
);

sub run_dataset {
    my $self = shift;

    my @bet_range   = sort { $a <=> $b } split '-', $self->run_only;
    my @pre_filters = ($bet_range[0] .. $bet_range[1]);
    my $merlin_csv  = '/home/git/bom/t/BOM/Product/Benchmark/csv/merlin/COMPLETE.csv';

    my $parser = Benchmark::CSVParser::Merlin->new(
        merlin_csv  => $merlin_csv,
        pre_filters => \@pre_filters,
        suite       => $self->suite,
    );

    my $report = $self->_calculate_results($parser);
    return $report;
}

sub _calculate_results {
    my ($self, $parser) = @_;

    $self->_save_full_result_header;

    my $full_report_file = $self->_report_file->{all};
    my @output;
    my $analysis_mid_diffs;

    foreach my $record (@{$parser->records}) {
        my $bet_args = _get_bet_args($record);

        next if _skip($record);

        my $bet      = produce_contract($bet_args);
        my $bet_type = $bet->bet_type->code;

        my $base_or_num   = ($record->{numeraire} eq $record->{currency}) ? 'NUM' : 'BASE';
        my $merlin_mid    = ($record->{merlin_ask} + $record->{merlin_bid}) / 2;
        my $arb_available = ($bet->bid_probability->amount > $record->{merlin_ask} or $bet->ask_probability->amount < $record->{merlin_bid}) ? 1 : 0;
        my $tv_diff       = abs($record->{merlin_tv} - $bet->bs_probability->amount);
        my $mid_diff      = abs($merlin_mid - $bet->theo_probability->amount);
        my @barriers      = $bet->two_barriers ? ($bet->high_barrier->as_absolute, $bet->low_barrier->as_absolute) : ($bet->barrier->as_absolute);

        my @output_array = (
            $record->{bet_num},                  $record->{volcut},             $record->{cut},
            $record->{currency},                 $record->{underlying}->symbol, $bet_type,
            $record->{date_start}->date_ddmmmyy, $record->{date_expiry}->date,  $bet->pricing_spot,
            @barriers,,                          $record->{merlin_tv},
            $bet->bs_probability->amount,        $tv_diff,                      $merlin_mid,
            $bet->theo_probability->amount,      $mid_diff,                     $record->{atm_vol},
            $bet->atm_vols->{fordom},            $arb_available,                $base_or_num,
            $record->{transformed_cut});

        my $string = join ',', @output_array;
        $string .= "\n";

        append_file($full_report_file, $string);
        push @output, \@output_array;
        push @{$analysis_mid_diffs->{$base_or_num}->{$bet_type}}, $mid_diff;
    }

    my $analysis_result = $self->_generates_and_saves_analysis_report($analysis_mid_diffs);
    my $record_num      = scalar(@output);

    return $analysis_result;
}

sub _get_bet_args {
    my $record = shift;
    my $when   = Date::Utility->new($record->{date_start});

    return {
        current_spot => $record->{spot},
        underlying   => $record->{underlying},
        q_rate       => $record->{q_rate},
        r_rate       => $record->{r_rate},
        barrier      => $record->{barrier},
        barrier2     => $record->{barrier2},
        bet_type     => $record->{bet_type},
        date_start   => $when,
        date_expiry  => $record->{date_expiry},
        volsurface   => $record->{surface},
        payout       => $record->{payout},
        currency     => $record->{currency},
        date_pricing => $record->{date_start},
    };
}

sub _skip {
    my $record = shift;

    my $bet_duration = $record->{date_expiry}->epoch - $record->{date_start}->epoch;
    return (not $record->{spot} or $bet_duration > 365 * 86400) ? 1 : 0;
}

sub _generates_and_saves_analysis_report {
    my ($self, $mid_diffs) = @_;
    my $file = $self->_report_file->{'analysis'};
    write_file($file, "\n");

    my $analysis_result;
    foreach my $price_type ($mid_diffs) {
        foreach my $base_or_num (keys %$price_type) {
            my $cap_base_or_num = uc $base_or_num;
            append_file($file, $cap_base_or_num . ' ANALYSIS REPORT:' . "\n\n" . 'BET_TYPE,AVG_MID,MAX_MID' . "\n");
            foreach my $bet_type (keys %{$price_type->{$base_or_num}}) {
                my @diff = @{$price_type->{$base_or_num}->{$bet_type}};
                my $avg  = sum(@diff) / scalar(@diff);
                my $max  = max(@diff);
                $analysis_result->{$base_or_num}->{$bet_type}->{avg} = $avg;
                $analysis_result->{$base_or_num}->{$bet_type}->{max} = $max;
                append_file($file, "$bet_type,$avg,$max\n");
            }
            append_file($file, "\n\n");
        }
    }

    return $analysis_result;
}

sub _save_full_result_header {
    my $self        = shift;
    my $output_file = $self->_report_file->{all};
    my $csv_title   = join ',', qw(
        bet_num vol_cut option_cut currency underlying_symbol   bet_type   date_start date_expiry         S
        barrier         barrier2    merlin_tv bom_tv tv_diff merlin_mid bom_mid mid_diff merlin_atm_vol bom_atm_vol arb_avail base_or_num transformed_cut
    );

    write_file($output_file, "$csv_title\n");
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
