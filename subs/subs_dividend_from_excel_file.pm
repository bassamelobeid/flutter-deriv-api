## no critic (RequireExplicitPackage)
use strict;
use warnings;

use open qw[ :encoding(UTF-8) ];

use Syntax::Keyword::Try;
use Spreadsheet::ParseExcel::Workbook;
use Format::Util::Numbers qw(roundcommon);
use Date::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData::Types;
use SuperDerivatives::UnderlyingConfig;
use Quant::Framework::Asset;
use BOM::Config::Chronicle;
use BOM::Backoffice::Request;
use Text::CSV::Slurp;
use YAML::XS qw(LoadFile);
use Quant::Framework::DividendPoint;

sub upload_dividend_point {
    my ($fh, $market) = @_;

    my ($data, $skipped) = parse_gbe_dividend($fh, $market);

    return 'No data is uploaded' unless $data and %$data;

    my (@saved, @exception);
    foreach my $symbol (keys %$data) {
        try {
            Quant::Framework::DividendPoint->new(
                symbol           => $symbol,
                dividend_points  => $data->{$symbol}{dividend_points},
                recorded_date    => Date::Utility->new,
                chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
            )->save;
            push @saved, $symbol;
        } catch {
            warn $_;
            push @exception, $symbol;
        };
    }

    my $output =
          scalar(@saved)
        . ' symbols uploaded. '
        . scalar(@$skipped)
        . ' symbols could not be parsed. '
        . scalar(@exception)
        . ' symbols throw exception.';
    return $output;
}

sub compare_dividend_point {
    my ($bb_fh, $gbe_fh, $market) = @_;

    my ($bb_data)  = parse_bloomberg_dividend($bb_fh, $market);
    my ($gbe_data) = parse_gbe_dividend($gbe_fh, $market);

    my @comparison;
    # compare using GBE data as reference
    foreach my $symbol (keys %$gbe_data) {
        foreach my $date (keys %{$gbe_data->{$symbol}{dividend_points}}) {
            my $gbe_point = $gbe_data->{$symbol}{dividend_points}{$date};
            my $bb_point  = $bb_data->{$symbol}{dividend_points}{$date};
            if ($bb_point) {
                my $diff = roundcommon(0.01, abs($gbe_point - $bb_point) / $gbe_point * 100);
                push @comparison,
                    {
                    symbol => $symbol,
                    date   => $date,
                    gbe    => $gbe_point,
                    bb     => $bb_point,
                    diff   => $diff
                    };
            }
        }
    }

    return 'No matching dividend point for comparison' unless @comparison;

    my $table;
    BOM::Backoffice::Request::template()->process(
        'backoffice/dividend_comparison_table.html.tt',
        {
            data => \@comparison,
        },
        \$table
    ) || die BOM::Backoffice::Request::template()->error();

    return $table;
}

sub process_dividend {
    my ($fh) = @_;

    my ($data, $skipped) = parse_bloomberg_dividend($fh, 'indices');

    save_dividends($data);

    my $number_of_underlyings_processed = scalar keys %$data;
    my $skipped_string                  = join ',', @$skipped;
    my $success_msg = 'Processed dividends for ' . $number_of_underlyings_processed . ' underlyings. Skipped [' . $skipped_string . ']';

    return $success_msg;
}

sub save_dividends {
    my ($data) = @_;

    foreach my $symbol (keys %{$data}) {
        my $rates = $data->{$symbol}->{dividend_yields};

        if (not $rates) {
            $rates = {365 => 0};
        }

        try {
            my $dividends = Quant::Framework::Asset->new(
                symbol           => $symbol,
                rates            => $rates,
                recorded_date    => Date::Utility->new,
                chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
            );

            $dividends->save;
        } catch {
            print " We are having error for $symbol: $@";
        }
    }
    return;
}

my $gbe_symbol_mapper;

sub parse_gbe_dividend {
    my ($fh, $market) = @_;

    my $now = Date::Utility->new;
    my $csv = Text::CSV::Slurp->load(filehandle => $fh);

    return _parse_gbe_index_dividend($csv)  if $market eq 'indices';
    return _parse_gbe_stocks_dividend($csv) if $market eq 'stocks';
}

sub _parse_gbe_index_dividend {
    my $csv = shift;

    $gbe_symbol_mapper //= LoadFile('/home/git/regentmarkets/bom-backoffice/config/gbe_dividend_symbol_mapper.yml');

    my $div_data;
    my @skipped;
    foreach my $data (@$csv) {
        my $symbol        = delete $data->{'Indices/Dates'};
        my $binary_symbol = $gbe_symbol_mapper->{$symbol};

        # skip if we don't know what it is
        unless ($binary_symbol) {
            push @skipped, $symbol;
            next;
        }
        foreach my $date (keys %$data) {
            die 'invalid date format ' . $date if ($date !~ /\d{1,2}\/\d{1,2}\/\d{4}/);
            my $point = $data->{$date};
            next unless $point;
            $date =~ s/\//-/g;
            $date = Date::Utility->new($date);
            $div_data->{$binary_symbol}->{dividend_points}{$date->plus_time_interval('1d')->date_yyyymmdd} = $point;
        }
    }

    return ($div_data, \@skipped);
}

sub _parse_gbe_stocks_dividend {
    my $csv = shift;

    $gbe_symbol_mapper //= LoadFile('/home/git/regentmarkets/bom-backoffice/config/gbe_dividend_symbol_mapper.yml');

    my $div_data;
    my @skipped;
    foreach my $data (@$csv) {
        my $binary_symbol = $gbe_symbol_mapper->{$data->{Symbol}};
        # skip if we don't know what it is
        unless ($binary_symbol) {
            push @skipped, $data->{Symbol};
            next;
        }
        my $point = $data->{Summary};
        next unless $point and looks_like_number($point);
        my $ex_date = $data->{'Ex-Date'};
        die 'invalid date format ' . $ex_date if ($ex_date !~ /\d{1,2}\/\d{1,2}\/\d{4}/);
        $ex_date =~ s/\//-/g;
        # there's no need calculate dividend yield for stocks
        $div_data->{$binary_symbol}->{dividend_points}->{Date::Utility->new($ex_date)->date_yyyymmdd} = $point;
    }
    return ($div_data, \@skipped);
}

## The relevant data is either get from BDVD <GO> or SD
## The excel file is consisting of daily BB discrete forecasted dividend point or SD discrete implied dividend
## We will convert them to annualized dividend yields
sub parse_bloomberg_dividend {
    my ($fh, $market) = @_;

    my $excel = Spreadsheet::ParseExcel::Workbook->Parse($fh);

    return _parse_bloomberg_index_dividend($excel)  if $market eq 'indices';
    return _parse_bloomberg_stocks_dividend($excel) if $market eq 'stocks';
}

my $bloomberg_symbol_mapper;

sub _parse_bloomberg_index_dividend {
    my $excel = shift;

    my @default_term = (1 .. 365);
    my $first_row    = 1;
    my $data;
    my $now = Date::Utility->new;
    $bloomberg_symbol_mapper //= LoadFile('/home/git/regentmarkets/bom-backoffice/config/bloomberg_dividend_symbol_mapper.yml');

    my @skipped;
    SHEET: foreach my $sheet (@{$excel->{'Worksheet'}}) {
        my $symbol        = uc($sheet->{'Name'});
        my $binary_symbol = $bloomberg_symbol_mapper->{$symbol};
        next unless $binary_symbol;

        my $underlying = create_underlying($binary_symbol);
        my $spot       = $underlying->spot;
        unless ($spot) {
            push @skipped, $binary_symbol;
            next SHEET;
        }

        my ($row_min, $row_max) = $sheet->RowRange();

        FIX_TERM: for (my $j = 0; $j < scalar(@default_term); $j++) {
            EXPIRY: for (my $i = $first_row; $i <= $row_max; $i++) {
                my $ex_date_cell        = $sheet->Cell($i, 0);
                my $dividend_point_cell = $sheet->Cell($i, 2);
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
                } elsif ($ex_date =~ /(\d{1,2})\-(\w{3})\-(\d{4})/) {
                    $ex_div = Date::Utility->new($ex_date);
                }

                $data->{$underlying->symbol}->{dividend_points}->{$ex_div->date_yyyymmdd} = $dividend_point if $dividend_point;
                my $fix_term = $ex_div->days_between($now);

                next EXPIRY   if ($fix_term <= 0);
                next FIX_TERM if ($fix_term > $default_term[$j]);

                $data->{$underlying->symbol}->{aggregated_dividend_points}->{$default_term[$j]} += $dividend_point;
            }
        }

        foreach my $term (sort { $a <=> $b } keys %{$data->{$underlying->symbol}->{aggregated_dividend_points}}) {
            my $div_rate = roundcommon(0.01, (($data->{$underlying->symbol}->{aggregated_dividend_points}->{$term} / $spot) * 365 / $term) * 100);

            # do not store if dividend > 10%
            if (not is_dividend_in_bounds($div_rate, $term)) {
                next SHEET;
            }

            $data->{$underlying->symbol}->{dividend_yields}->{$term} = $div_rate;
        }
    }

    return ($data, \@skipped);
}

sub _parse_bloomberg_stocks_dividend {
    my $excel = shift;

    my @default_term = (1 .. 365);
    my $first_row    = 1;
    my $data;
    my $now = Date::Utility->new;
    $bloomberg_symbol_mapper //= LoadFile('/home/git/regentmarkets/bom-backoffice/config/bloomberg_dividend_symbol_mapper.yml');

    my @skipped;
    SHEET: foreach my $sheet (@{$excel->{'Worksheet'}}) {
        my $symbol        = uc($sheet->{'Name'});
        my $binary_symbol = $bloomberg_symbol_mapper->{$symbol};
        next unless $binary_symbol;

        my ($row_min, $row_max) = $sheet->RowRange();

        FIX_TERM: for (my $j = 0; $j < scalar(@default_term); $j++) {
            EXPIRY: for (my $i = $first_row; $i <= $row_max; $i++) {
                my $ex_date_cell        = $sheet->Cell($i, 0);
                my $dividend_point_cell = $sheet->Cell($i, 2);
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
                } elsif ($ex_date =~ /(\d{1,2})\-(\w{3})\-(\d{4})/) {
                    $ex_div = Date::Utility->new($ex_date);
                }

                $data->{$binary_symbol}->{dividend_points}->{$ex_div->date_yyyymmdd} = $dividend_point if $dividend_point;
            }
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

sub generate_dividend_point_upload_form {
    my ($args, $disabled_write) = @_;

    my $form;
    BOM::Backoffice::Request::template()->process(
        'backoffice/dividend_point_upload_form.html.tt',
        {
            broker     => $args->{broker},
            upload_url => $args->{upload_url},
            disabled   => $disabled_write,
        },
        \$form
    ) || die BOM::Backoffice::Request::template()->error;

    return $form;
}

sub generate_dividend_comparison_form {
    my ($args, $disabled_write) = @_;

    my $form;
    BOM::Backoffice::Request::template()->process(
        'backoffice/dividend_comparison_form.html.tt',
        {
            broker     => $args->{broker},
            upload_url => $args->{upload_url},
            disabled   => $disabled_write,
        },
        \$form
    ) || die BOM::Backoffice::Request::template()->error;

    return $form;
}

sub generate_dividend_upload_form {
    my $args           = shift;
    my $disabled_write = shift;

    my $form;
    BOM::Backoffice::Request::template()->process(
        'backoffice/dividend_upload_form.html.tt',
        {
            broker     => $args->{broker},
            upload_url => $args->{upload_url},
            disabled   => $disabled_write,
        },
        \$form
    ) || die BOM::Backoffice::Request::template()->error;

    return $form;
}

1;
