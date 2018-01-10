package Runner::Merlin;

use Moose;
use lib qw(/home/git/regentmarkets/bom/t/BOM/Product);
use Date::Utility;
use Postgres::FeedDB::Spot::Tick;
use BOM::Product::ContractFactory qw( produce_contract );
use CSVParser::Merlin;

use List::Util qw(max sum);
use Path::Tiny;
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
            all      => path('/tmp/merlin_full_result.csv'),
            analysis => path('/tmp/merlin_analysis_result.csv'),
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
    my $merlin_csv  = '/home/git/regentmarkets/bom-quant-benchmark/t/csv/merlin/COMPLETE.csv';

    my $parser = CSVParser::Merlin->new(
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
        $bet_args->{current_tick} = Postgres::FeedDB::Spot::Tick->new(
            underlying => $bet_args->{underlying}->symbol,
            quote      => $bet_args->{current_spot},
            epoch      => $bet_args->{date_start}->epoch,
        );

        my $bet           = produce_contract($bet_args);
        my $bet_type      = $bet->code;
        my $base_or_num   = ($record->{numeraire} eq $record->{currency}) ? 'NUM' : 'BASE';
        my $merlin_mid    = ($record->{merlin_ask} + $record->{merlin_bid}) / 2;
        my $arb_available = ($bet->bid_probability->amount > $record->{merlin_ask} or $bet->ask_probability->amount < $record->{merlin_bid}) ? 1 : 0;

        my $bs_prob = $bet->pricing_engine->can('_bs_probability') ? $bet->pricing_engine->_bs_probability : $bet->pricing_engine->bs_probability;
        my $base_prob = $bet->pricing_engine->can('_base_probability') ? $bet->pricing_engine->_base_probability : $bet->pricing_engine->base_probability;

        $bs_prob = $bs_prob->amount if ref $bs_prob;
        $base_prob = $base_prob->amount if ref $base_prob;

        my $tv_diff       = abs($record->{merlin_tv} - $bs_prob);
        my $mid_diff      = abs($merlin_mid - $base_prob);
        my @barriers = $bet->two_barriers ? ($bet->high_barrier->as_absolute, $bet->low_barrier->as_absolute) : ($bet->barrier->as_absolute, 'NA');

        my @output_array = (
            $record->{bet_num},            $record->{volcut},        $record->{cut},                      $record->{currency},
            $record->{underlying}->symbol, $bet_type,                $record->{date_start}->date_ddmmmyy, $record->{date_expiry}->date,
            $bet->pricing_spot,            @barriers,                $record->{merlin_tv},                $bet->theo_probability,
            $tv_diff,                      $merlin_mid,              $base_prob,                             $mid_diff,
            $record->{atm_vol},            $bet->atm_vols->{fordom}, $arb_available,                      $base_or_num,
            $record->{transformed_cut});

        my $string = join ',', @output_array;
        $string .= "\n";

        $full_report_file->append($string);
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
    $record->{surface}->{creation_date} = $when;
    my $args   = {
        current_spot => $record->{current_spot},
        underlying   => $record->{underlying},
        q_rate       => $record->{q_rate},
        r_rate       => $record->{r_rate},
        bet_type     => $record->{bet_type},
        date_start   => $when,
        date_expiry  => $record->{date_expiry},
        volsurface   => $record->{surface},
        payout       => $record->{payout},
        currency     => $record->{currency},
        date_pricing => $record->{date_start},
        uses_empirical_volatility => 0,
    };

    if ($record->{barrier}) {
        $args->{barrier} = $record->{barrier};
    } elsif ($record->{high_barrier}) {
        $args->{high_barrier} = $record->{high_barrier};
        $args->{low_barrier}  = $record->{low_barrier};
    }

    return $args;

}

sub _skip {
    my $record = shift;

    my $bet_duration = $record->{date_expiry}->epoch - $record->{date_start}->epoch;
    return (not $record->{current_spot} or $bet_duration > 365 * 86400) ? 1 : 0;
}

sub _generates_and_saves_analysis_report {
    my ($self, $mid_diffs) = @_;
    my $file = $self->_report_file->{'analysis'};
    $file->spew("\n");

    my $analysis_result;
    foreach my $price_type ($mid_diffs) {
        foreach my $base_or_num (keys %$price_type) {
            my $cap_base_or_num = uc $base_or_num;
            $file->append($cap_base_or_num . ' ANALYSIS REPORT:' . "\n\n" . 'BET_TYPE,AVG_MID,MAX_MID' . "\n");
            foreach my $bet_type (keys %{$price_type->{$base_or_num}}) {
                my @diff = @{$price_type->{$base_or_num}->{$bet_type}};
                my $avg  = sum(@diff) / scalar(@diff);
                my $max  = max(@diff);
                $analysis_result->{$base_or_num}->{$bet_type}->{avg} = $avg;
                $analysis_result->{$base_or_num}->{$bet_type}->{max} = $max;
                $file->append("$bet_type,$avg,$max\n");
            }
            $file->append("\n\n");
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

    $output_file->spew("$csv_title\n");
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
