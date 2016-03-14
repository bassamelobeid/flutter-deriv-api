use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use Try::Tiny;
use Spreadsheet::ParseExcel;
use Format::Util::Numbers qw(roundnear);
use Date::Utility;
use BOM::Market::Underlying;
use SuperDerivatives::UnderlyingConfig;
use Quant::Framework::Dividend;
use BOM::System::Chronicle;


sub process_dividend {
    my ($fh, $vendor) = @_;

    my ($data, $skipped);
    ($data, $skipped) = read_discrete_forecasted_dividend_from_excel_files($fh, $vendor);
    die 'No data was read' if not keys %$data;
    save_dividends($data);

    my $number_of_underlyings_processed = scalar keys %$data;
    my $skipped_string = join ',', @$skipped;
    my $success_msg = 'Processed dividends for ' . $number_of_underlyings_processed . ' underlyings. Skipped [' . $skipped_string . ']';

    return $success_msg;
}

sub save_dividends {
    my ($data) = @_;

    my %valid_synthetic = map { $_ => 1 } BOM::Market::UnderlyingDB->get_symbols_for(
        market    => 'indices',
        submarket => 'smart_index'
    );

    foreach my $symbol (keys %{$data}) {
        my $rates           = $data->{$symbol}->{dividend_yields};
        my $discrete_points = $data->{$symbol}->{discrete_points};

        if (not $rates) {
            $rates = {365 => 0};
        }

        if (not $discrete_points) {
            my $now = Date::Utility->new->date_yyyymmdd;
            $discrete_points = {$now => 0};

        }
        try {
            my $dividends = Quant::Framework::Dividend->new(
                symbol          => $symbol,
                rates           => $rates,
                discrete_points => $discrete_points,
                recorded_date   => Date::Utility->new,
                chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            );
            if (exists $valid_synthetic{'SYN' . $symbol}) {
                my $synthetic_dividend = Quant::Framework::Dividend->new(
                    symbol          => 'SYN' . $symbol,
                    rates           => $rates,
                    discrete_points => $discrete_points,
                    recorded_date   => Date::Utility->new,
                    chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
                    chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
                );
                $synthetic_dividend->save;
            }

            $dividends->save;
        }
        catch {
            print " We are having error for $symbol: $_";
        };
    }

}

## The relevant data is either get from BDVD <GO> or SD
## The excel file is consisting of daily BB discrete forecasted dividend point or SD discrete implied dividend
## We will convert them to annualized dividend yields
sub read_discrete_forecasted_dividend_from_excel_files {
    my ($fh, $source) = @_;

    my @default_term = (1 .. 365);

    my $data_location = {};
    my $first_row;
    if ($source eq 'BB') {
        $data_location->{'Ex-Date'}         = ['x', 0];
        $data_location->{'dividend_points'} = ['x', 2];
        $first_row                          = 1;
    } elsif ($source eq 'SD') {
        $data_location->{'Ex-Date'}         = ['x', 4];
        $data_location->{'dividend_points'} = ['x', 5];
        $first_row                          = 8;
    }

    my $data;
    my $now = Date::Utility->new;

    my $sheet_counter = 1;

    my $excel = Spreadsheet::ParseExcel::Workbook->Parse($fh);

    my @skipped;
    SHEET: foreach my $sheet (@{$excel->{'Worksheet'}}) {
        my $symbol = uc($sheet->{'Name'});
        # ON SD sheet,the sheets named SD or BB is for volatility , no need to process it
        if (grep { $symbol eq $_ } ('SD', 'BB', 'GET DATA PARAMETERS', 'MD PROCESS RESULTS', 'MASTER')) {
            next SHEET;
        }

        if ($source eq 'SD') {
            $symbol = SuperDerivatives::UnderlyingConfig::sd_to_binary($symbol);
            # skipping these because SuperDerivatives doesn't provide dividend
            # information on these underlyings
            if (not $symbol or grep { $symbol eq $_ } qw(STI IXIC)) {
                next SHEET;
            }
        }

        my $underlying = BOM::Market::Underlying->new($symbol);
        my $spot       = $underlying->spot;
        unless ($spot) {
            push @skipped, $underlying->symbol;
            next;
        }

        my $underlying_symbol = $underlying->symbol;

        my ($row_min, $row_max) = $sheet->RowRange();

        FIX_TERM: for (my $j = 0; $j < scalar(@default_term); $j++) {
            EXPIRY: for (my $i = $first_row; $i <= $row_max; $i++) {
                my $ex_date_cell        = $sheet->Cell($i, $data_location->{'Ex-Date'}->[1]);
                my $dividend_point_cell = $sheet->Cell($i, $data_location->{'dividend_points'}->[1]);
                my $ex_date             = $ex_date_cell->{'Val'};

                next EXPIRY if not $ex_date;

                my $dividend_point = $dividend_point_cell->{'Val'};

                my $ex_div;
                # the ex_date from bloomberg is in this format 5/30/10
                if ($ex_date =~ /(\d{1,2})\/(\d{1,2})\/(\d{2})$/) {
                    my $year = $3;
                    if ($year < 99) {
                        $year = '20' . $year;
                    }
                    $ex_div = Date::Utility->new($year . '-' . sprintf('%02d', $1) . '-' . sprintf('%02d', $2));
                } elsif ($ex_date =~ /(\w{3})\s+(\d{1,2})\s+(\d{4})\s?$/) {
                    $ex_div = Date::Utility->new(sprintf('%02d', $2) . '-' . $1 . '-' . sprintf('%02d', $3));
                }elsif ($ex_date =~ /(\d{1,2})\-(\w{3})\-(\d{4})/){
                    $ex_div = Date::Utility->new($ex_date);
                }

                my $fix_term = $ex_div->days_between($now);

                next EXPIRY   if ($fix_term <= 0);
                next FIX_TERM if ($fix_term > $default_term[$j]);

                $data->{$underlying_symbol}->{dividend_points}->{$default_term[$j]} += $dividend_point;
                $data->{$underlying_symbol}->{discrete_points}->{$ex_div->date_yyyymmdd} = $dividend_point;
            }
        }

        foreach my $term (sort { $a <=> $b } keys %{$data->{$underlying_symbol}->{dividend_points}}) {
            my $div_rate = roundnear(0.01, (($data->{$underlying_symbol}->{dividend_points}->{$term} / $spot) * 365 / $term) * 100);

            # do not store if dividend > 10%
            if (not is_dividend_in_bounds($div_rate, $term)) {

                next SHEET;
            }

            $data->{$underlying_symbol}->{dividend_yields}->{$term} = $div_rate;
        }
    }

    return ($data, \@skipped);
}

sub is_dividend_in_bounds {
    # Rate must be in annualized form and multiplied by 100.
    my ($annualized_rate_pc, $div_days) = @_;

    my $is_dividend_in_bounds = 1;

    # Ad hoc value of not more than 10 percent annualized rate
    my $limit = 10;

    # For dividend rates less than a year, they are always magnified. For example a 1 week dividend rate
    # assumes that this dividend is given for every week of the year, thus magnified 52 times.
    # Therefore, we have to adjust this value by removing the grossly misleading inflating factor.
    # For longer days, the error becomes less extreme, and we can ignore it since this is only a limit check.
    my $effective_rate = $annualized_rate_pc / (365 / $div_days);

    if ($annualized_rate_pc < 0 or $effective_rate < 0 or $effective_rate > $limit) {
        $is_dividend_in_bounds = 0;
    }

    return $is_dividend_in_bounds;
}

sub generate_dividend_upload_form {
    my $args = shift;

    my $form;
    BOM::Platform::Context::template->process(
        'backoffice/dividend_upload_form.html.tt',
        {
            broker     => $args->{broker},
            upload_url => $args->{upload_url},
        },
        \$form
    ) || die BOM::Platform::Context::template->error;

    return $form;
}

1;
