package Runner::Superderivatives_FX;

use Moose;

use lib ("/home/git/regentmarkets/bom/t/BOM/Product");

use Path::Tiny;
use List::Util qw(sum max);
use Text::CSV;
use Carp;

use CSVParser::Superderivatives_FX;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::FeedTestDatabase;
use Date::Utility;
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
            all_base      => path('/tmp/sdfx_base_result_file.csv'),
            all_num       => path('/tmp/sdfx_num_result_file.csv'),
            analysis_num  => path('/tmp/sdfx_num_analysis_file.csv'),
            analysis_base => path('/tmp/sdfx_base_analysis_file.csv'),
        };
    },
);

sub run_dataset {
    my $self = shift;
    my $key  = shift;

    my @files;

    my $key_base = 'BASE';
    my $key_num  = 'NUM';
    if ($key) {
        @files    = $key eq 'major' ? qw(SD_EURUSD SD_USDJPY SD_GBPJPY) : qw(SD_USDSEK SD_GBPPLN SD_GBPAUD SD_USDCHF);
        $key_base = uc($key) . '_BASE';
        $key_num  = uc($key) . '_NUM';
    } else {
        @files = qw(SD_EURUSD SD_USDJPY SD_GBPJPY SD_USDCHF SD_GBPAUD SD_USDSEK SD_GBPPLN);
    }
    my $result_all;

    my $csv_title =
        "ID,underlying,bet_type,spot,barrier,barrier2,duration(days),date_start,date_expiry,BOM_pricing_args_iv,SD_mid,BOM_mid,mid_diff,arbitrage_check_base";
    $self->report_file->{all_base}->spew($csv_title . "\n");
    $self->report_file->{all_num}->spew($csv_title . "\n");

    my $analysis_title = "BET_TYPE,AVG_MID_DIFF,MAX_MID_DIFF\n";
    $self->report_file->{analysis_base}->spew($analysis_title);
    $self->report_file->{analysis_num}->spew($analysis_title);

    my $base_results;
    my $num_results;

    foreach my $file (@files) {
        my $file_loc = '/home/git/regentmarkets/bom-quant-benchmark/t/csv/superderivatives';
        my $file     = $file_loc . '/' . $file . '.csv';
        my $records  = CSVParser::Superderivatives_FX->new(
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
        $key_num  => $numeraire_analysis_report,
        $key_base => $base_analysis_report,
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
        $file->append("$bet_type,$avg,$max\n");
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
        my $raw_surface  = $record->{volsurface};
        my $payout       = $record->{payout};
        my $date_pricing = $record->{date_start};
        my $spot         = $record->{spot};
        my $days_between = $date_expiry->days_between($date_start);

        next if $date_expiry->epoch - $date_start->epoch > 365 * 86400;
        next if $date_expiry->is_a_weekend or $date_start->is_a_weekend;

        my $currency = ($base_or_num eq 'base') ? $record->{base_currency} : $record->{numeraire_currency};
        my $bet_type = $record->{bet_type};
        my $bet_args = {
            underlying                => $underlying,
            bet_type                  => $bet_type,
            date_start                => $date_start,
            date_expiry               => $date_expiry,
            volsurface                => $raw_surface,
            payout                    => $payout,
            currency                  => $currency,
            date_pricing              => $date_start,
            current_spot              => $spot,
            uses_empirical_volatility => 0,
        };

        if ($record->{barrier2}) {
            $bet_args->{high_barrier} = $record->{barrier};
            $bet_args->{low_barrier}  = $record->{barrier2};
        } else {
            $bet_args->{barrier} = $record->{barrier};
        }
        $bet_args->{current_tick} = Postgres::FeedDB::Spot::Tick->new(
            underlying => $bet_args->{underlying}->symbol,
            quote      => $bet_args->{current_spot},
            epoch      => $bet_args->{date_start}->epoch,
        );

        BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick({
            underlying => $bet_args->{underlying}->symbol,
            quote      => $bet_args->{current_spot},
            epoch      => $bet_args->{date_start}->epoch,
        });

        #force re-createion of surface
        $record->{volsurface}->clear_surface;
        my $bet = produce_contract($bet_args);

        my $bom_mid =
            $bet->pricing_engine->can('_base_probability') ? $bet->pricing_engine->_base_probability : $bet->pricing_engine->base_probability->amount;
        my $bom_bs =
            $bet->pricing_engine->can('_bs_probability') ? $bet->pricing_engine->_bs_probability : $bet->pricing_engine->bs_probability->amount;

        my $sd_mid   = $record->{sd_mid};
        my @barriers = $bet->two_barriers ? ($bet->high_barrier->as_absolute, $bet->low_barrier->as_absolute) : ($bet->barrier->as_absolute, 'NA');
        next if $sd_mid < 0.05 or $sd_mid > 0.95;

        my $sd_bid = $record->{sd_bid};
        my $sd_ask = $record->{sd_ask};

        my $mid_diff = abs($sd_mid - $bom_mid);

        #force re-createion of surface
        $record->{volsurface}->clear_surface;
        $bet = produce_contract($bet_args);

        my $arbitrage_check = ($bet->bid_probability->amount > $sd_ask or $bet->ask_probability->amount < $sd_bid) ? 1 : 0;

        $csv->combine(
            $record->{ID}, $underlying->symbol,       $bet_type,          $spot,                     @barriers,
            $days_between, $date_start->date_ddmmmyy, $date_expiry->date, $bet->_pricing_args->{iv}, $sd_mid,
            $bom_mid,      $mid_diff,                 $arbitrage_check
        );
        my $result = $csv->string;
        if ($base_or_num eq 'base') {
            $self->report_file->{all_base}->append("$result\n");
            push @{$analysis_results->{$bet_type}}, $mid_diff;
        } else {

            $self->report_file->{all_num}->append("$result\n");
            push @{$analysis_results->{$bet_type}}, $mid_diff;

        }
    }

    return $analysis_results;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
