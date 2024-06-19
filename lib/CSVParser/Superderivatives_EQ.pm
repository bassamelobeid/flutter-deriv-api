package CSVParser::Superderivatives_EQ;

use Moose;
use IO::File;
use List::Util qw(max min);

use Math::Function::Interpolator;
use Quant::Framework::CorrelationMatrix;
use BOM::MarketData qw(create_underlying);
use Quant::Framework::VolSurface::Moneyness;
use SetupDatasetTestFixture;
use Date::Utility;
use Scalar::Util qw(looks_like_number);
use BOM::Config::Chronicle;

has file => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has records => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy_build => 1,
);

has suite => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
);

sub _build_records {
    my $self = shift;
    my $data = $self->read_the_lines_and_parse_the_categories($self->file);

    my $surface_data = $self->calculate_moneyness_surface($data);
    my $time         = $data->{time};
    my ($hour, $minute) = $time =~ /(\d{2}):(\d{2}) GMT/;

    return if not $hour or not $minute;

    my $start_offset = ($hour - 8) * 3600 + $minute * 60;        # in seconds
    my $underlying   = create_underlying($data->{underlying});
    my $rates        = $self->get_rates($data, $underlying);
    my $date_start   = Date::Utility->new($data->{date});
    my $spot         = $data->{spot};
    my $currency     = $data->{currency};

    my $surface = Quant::Framework::VolSurface::Moneyness->new(
        underlying       => $underlying,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        surface          => $surface_data,
        creation_date    => Date::Utility->new($date_start),
        spot_reference   => $spot,
        parameterization => {
            values            => $data->{sabr_params},
            calibration_error => 10,
            date              => Date::Utility->new
        },
    );

    my $fixture = SetupDatasetTestFixture->new();

    $fixture->setup_test_fixture({
        underlying => $underlying,
        rates      => $rates,
        spot       => $spot,
        date       => $date_start,
    });

    my @all_records;
    foreach my $record (@{$data->{records}}) {
        if ($self->suite eq 'mini' and not $record->{mini}) {
            next;
        }
        my $date_expiry  = Date::Utility->new($record->{expiry});
        my $days_between = $date_expiry->days_between($date_start);

        next if $days_between > 365;
        next if !looks_like_number($record->{mid});

        my $sd_mid   = $record->{mid} / 100;
        my $barrier  = (defined $record->{barrier})  ? $record->{barrier} / 100 * $spot  : undef;
        my $barrier2 = (defined $record->{barrier2}) ? $record->{barrier2} / 100 * $spot : undef;
        my $bet_type = $record->{bet_type};

        my $closing = $underlying->calendar->closing_on($underlying->exchange, $date_expiry);
        next unless $closing;
        my $params = {
            spot          => $spot,
            ID            => $record->{ID},
            underlying    => $underlying,
            volsurface    => $surface,
            date_start    => $date_start,
            date_expiry   => $date_expiry,
            expiry_offset => $closing->seconds_after_midnight,
            start_offset  => $start_offset,
            date_pricing  => $date_start,
            barrier       => $barrier,
            barrier2      => $barrier2,
            bet_type      => $bet_type,
            payout        => 1000,
            currency      => $currency,
            sd_mid        => $sd_mid,
        };
        push @all_records, $params;
    }

    return \@all_records;
}

sub _setup_correlations {
    my ($self, $args) = @_;

    my $underlying   = $args->{underlying};
    my $correlations = {$underlying->symbol => {$args->{correlated_currency} => $args->{data}}};
    my $correlation  = BOM::MarketData::CorrelationMatrix->new(
        symbol       => 'indices',
        date         => $args->{date},
        correlations => $correlations,
    );

    return $correlation->save;
}

sub _setup_quanto_rate {
    my ($self, $args, $date) = @_;

    my $symbol           = $args->{symbol};
    my $rates            = $args->{rates};
    my %applicable_rates = map { $_ => $rates->{$_} } grep { $_ <= 366 } keys %$rates;

    my $rate = Quant::Framework::InterestRate->new(
        symbol           => $symbol,
        rates            => \%applicable_rates,
        creation_date    => $date->datetime_iso8601,
        type             => 'market',
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
    );

    $rate->save;
}

sub _setup_quanto_volsurface {
    my ($self, $args, $date) = @_;

    my $underlying = create_underlying($args->{symbol});
    my $data       = $args->{data};
    my %surface_data;
    foreach my $term (keys %$data) {
        $surface_data{$term}->{smile} = {
            25 => $data->{$term} - 0.001,
            50 => $data->{$term},
            75 => $data->{$term} + 0.001
        };
        $surface_data{$term}->{vol_spread} = {50 => 0.12};
    }
    my $volsurface = Quant::Framework::VolSurface::Delta->new(
        surface          => \%surface_data,
        underlying       => $underlying,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        creation_date    => $date,
    );

    return $volsurface->save;
}

sub get_rates {
    my ($self, $data, $underlying) = @_;

    my $interest_rates = $data->{interest_rates}->{$underlying->quoted_currency->symbol} || $data->{interest_rates}->{default};
    my $dividends      = $data->{dividends};
    my $start_date     = $data->{date};

    my %r = map { $_ => $interest_rates->{$_} } grep { $_ <= 366 } keys %$interest_rates;

    my @dividend_terms = grep { $_ <= 366 } keys %$dividends;
    my %d =
        map { Date::Utility->new($start_date)->plus_time_interval($_ . 'd')->date_yyyymmdd => $dividends->{$_}->{discrete_point} }
        grep { $dividends->{$_}->{discrete_point} } @dividend_terms;

    my $min = min(@dividend_terms);
    my $max = max(@dividend_terms);
    my %q;
    foreach my $term ($min .. $max) {
        $q{$term} = $dividends->{$term}->{continuous} || $self->get_interpolated_rate($dividends, 'q_rate', $term);
        $q{$term} *= 100;
    }

    return {
        quoted_currency_rate => \%r,
        asset_rate           => {
            discrete   => \%d,
            continuous => \%q
        }};
}

sub get_interpolated_rate {
    my ($self, $term_structure, $rate_type, $days_between) = @_;

    my $rate_field;
    if ($rate_type eq 'r_rate') {
        $rate_field = 'Funding rate(%)';
    } else {
        $rate_field = 'continuous';
    }

    my @keys = grep { scalar(keys %{$term_structure->{$_}}) != 0 } sort { $a <=> $b } keys %{$term_structure};

    my $i = 0;
    while ($i < scalar(@keys) and $keys[$i] < $days_between) { $i++ }

    # When we dont have two point to interpolate, all days are above or below the day we want, we assume the rate if constant.
    # We will use the first days or the last day in this siutiations constantly as the rate.
    if ($i == 0)             { return $term_structure->{$keys[0]}->{$rate_field} }
    if ($i == scalar(@keys)) { return $term_structure->{$keys[$i - 1]}->{$rate_field} }

    my $r1 = $term_structure->{$keys[$i - 1]}->{$rate_field};
    my $r2 = $term_structure->{$keys[$i]}->{$rate_field};

    my $t1 = $keys[$i - 1];
    my $t2 = $keys[$i];

    return $r1 + ($r2 - $r1) / ($t2 - $t1) * ($days_between - $t1);
}

sub calculate_moneyness_surface {
    my ($self, $data) = @_;

    my $moneyness_smile = $data->{volsurface};
    my $surface_data;
    my $interpolator = Math::Function::Interpolator->new(points => $data->{vol_spread});

    foreach my $term (keys %$moneyness_smile) {

        my %modified_smile = map { $_ => $moneyness_smile->{$term}->{smile}->{$_} / 100 } keys %{$moneyness_smile->{$term}->{smile}};
        $surface_data->{$term}->{smile}      = \%modified_smile;
        $surface_data->{$term}->{vol_spread} = {100 => $interpolator->linear($term)};
    }

    return $surface_data;
}

sub read_the_lines_and_parse_the_categories {
    my ($self, $file) = @_;
    my $fh = IO::File->new;
    $fh->open('< ' . $file) or die('coould not open the file ' . $file);

    my %bet_type_map = (
        DIGITALCALL           => 'CALL',
        DIGITALPUT            => 'PUT',
        DOUBLENOTOUCH         => 'RANGE',
        NOTOUCH               => 'NOTOUCH',
        DOUBLEONETOUCHINSTANT => 'UPORDOWN',
        ONETOUCHINSTANT       => 'ONETOUCH',
        EXPIRYRANGE           => 'EXPIRYRANGE',
        ONETOUCH              => 'ONETOUCH',
    );
    my @bet;
    my $data;
    while (my $line = <$fh>) {
        if ($line =~ /^DATE,([^,]*),/) {
            $data->{'date'} = $1;
            next;
        }

        if ($line =~ /^TIME,([^,]*),/) {
            $data->{'time'} = $1;
            next;
        }

        if ($line =~ /^UNDERLYING,([^,]*),/) {
            $data->{'underlying'} = $1;
            next;
        }

        if ($line =~ /^SPOT,([^,]*),/) {
            $data->{'spot'} = $1;
            next;
        }

        if ($line =~ /^CURRENCY,([^,]*),/) {
            $data->{'currency'} = $1;
            next;
        }

        if ($line =~ /^SABR PARAMETERS/) {
            $data->{'sabr_params'} = $self->read_sabr_params($fh);
            next;
        }

        if ($line =~ /^VOL SURFACE STANDARD DATES,([^,]*),/) {
            my $vol_surface = read_vol_lines($fh, $data);
            my $moneyness   = vol_surface_to_moneyness($vol_surface);
            my @moneynesses = sort values %{$vol_surface->{atms}};
            delete $vol_surface->{atms};
            $data->{vol_surface} = $vol_surface;
            $data->{volsurface}  = $moneyness;
            $data->{moneynesses} = \@moneynesses;
            next;
        }

        if (my ($currency) = $line =~ /^TERM STRUCTURE STANDARD DATES\s?([A-Z]+)?,([^,]*),/) {
            $currency //= 'default';
            $data->{interest_rates}->{$currency} = $self->read_interest_rates($fh, $data);
            next;
        }
        if ($line =~ /^QUANTO CORRELATIONS (USD|GBP|EUR|AUD|JPY) (USD|GBP|JPY|EUR|AUD),([^,]*),/) {
            $data->{correlations} = $self->read_correlations($fh, $data);
            next;
        }

        if (my ($foreign_curr, $domestic_curr) = $line =~ /^FX Vol ([A-Z]+) ([A-Z]+)/) {
            $data->{quanto_volsurface}->{data}   = $self->read_quanto_volsurface($fh, $data);
            $data->{quanto_volsurface}->{symbol} = 'frx' . $foreign_curr . $domestic_curr;
        }

        if ($line =~ /^DIVIDENDS,([^,]*),/) {
            $data->{dividends} = $self->read_dividends($fh, $data);
            next;
        }

        if ($line =~ /^VOL SPREADS,([^,]*),/) {

            $data->{vol_spread} = $self->read_vol_spread_lines($fh);
            next;
        }

        if ($line =~ /^(ONETOUCH|NOTOUCH|DIGITALCALL|DIGITALPUT) PAYOUT (USD|GBP|EUR|AUD|JPY|HKD|CAD),([^,]*),/) {

            my $bet_type        = $1;
            my $payout_currency = $1;
            push @bet, @{$self->read_bets_single_barrier_lines($fh, $bet_type_map{$bet_type}, "END $bet_type PAYOUT")};

            next;
        }

        if ($line =~ /^(DOUBLENOTOUCH|EXPIRYRANGE) PAYOUT (USD|GBP|EUR|AUD|JPY|HKD|CAD|CNY),([^,]*),/) {

            my $bet_type        = $1;
            my $payout_currency = $2;
            push @bet, @{$self->read_bets_double_barrier_lines($fh, $bet_type_map{$bet_type}, "END $bet_type PAYOUT")};

            next;
        }
    }
    $data->{records} = \@bet;

    return $data;
}

sub read_sabr_params {
    my ($self, $fh) = @_;
    my $params;

    while (1) {
        my $line = <$fh>;
        if ($line =~ /^END SABR PARAMETERS/) {
            last;
        }
        $line =~ /^([^,]*),([^,]*),/;
        $params->{$1} = $2;
    }

    return $params;
}

sub read_vol_lines {
    my ($fh, $data) = @_;

    # %ATMS
    my $line = <$fh>;
    if ($line !~ /ATMS/) {
        die("Wrong file format [$line]");
    }
    $line =~ s/(\r|\n)+//g;
    my @atms = split(/,/, $line);

    #read the headers
    $line = <$fh>;
    if ($line !~ /Strike/i) {
        die("Wrong file format [$line]");
    }
    $line =~ s/(\r|\n)+//g;
    my @keys = split(/,/, $line);

    my $vol_surface;
    while (defined $fh and $line = <$fh> and $line !~ /END VOL SURFACE STANDARD DATES/) {
        $line =~ s/(\r|\n)+//g;
        if ($line =~ /^(\d+-\D+-\d+)/) {
            my $date   = $1;
            my @values = split(/,/, $line);

            for (my $i = 0; $i < 21; $i++) {
                #Possible duplicates will be ignored
                if ($values[1] eq '') { $values[1] = Date::Utility->new($values[0])->days_between(Date::Utility->new($data->{'date'})) }
                if (exists $vol_surface->{$values[1]}->{$keys[$i + 2]}) { next; }
                $vol_surface->{$values[1]}->{$keys[$i + 2]} = $values[$i + 2];
            }
        }
    }

    my %strikes = map { $keys[$_] => substr $atms[$_], 0, -1 } (2 .. scalar @atms - 1);
    $vol_surface->{atms} = \%strikes;

    return $vol_surface;
}

sub vol_surface_to_moneyness {
    my $vol_surface = shift;
    my $atms        = $vol_surface->{atms};
    my $moneyness   = {};

    for my $term (keys %{$vol_surface}) {
        next if $term eq 'atms';
        next if $term > 365;
        for my $strike (keys %{$vol_surface->{$term}}) {
            my $atm = $atms->{$strike};
            $moneyness->{$term}->{smile}->{$atm} = $vol_surface->{$term}->{$strike};
        }
    }

    return $moneyness;
}

sub read_dividends {
    my ($self, $fh, $data) = @_;
    my $structure;
    my $cummulative_point = 0;
    my $start_date        = Date::Utility->new($data->{date});

    while (my $line = <$fh>) {
        next if $line =~ /^Date/;
        last if $line =~ /END DIVIDENDS/;
        my @info           = split ',', $line;
        my $dividend_date  = $info[0];
        my $dividend_point = $info[1];
        my $days_between   = Date::Utility->new($dividend_date)->days_between($start_date);
        $structure->{$days_between}->{discrete_point} = $dividend_point;
        $cummulative_point += $dividend_point;
        $structure->{$days_between}->{continuous} = $cummulative_point / $data->{spot} * (365 / $days_between);
    }

    return $structure;
}

sub read_quanto_volsurface {
    my ($self, $fh, $data) = @_;
    #skip the line
    my $line = <$fh>;

    my $quanto_surface;
    while (defined $fh and $line = <$fh> and $line !~ /END FX Vol/) {
        $line =~ s/(\r|\n)+//g;
        my @volinfo = split(',', $line);
        my $days    = $volinfo[0];
        my $values  = $volinfo[1];
        $quanto_surface->{$days} = $values / 100;
    }

    return $quanto_surface;
}

sub read_correlations {
    my ($self, $fh, $data) = @_;
    #skip the line
    my $line = <$fh>;

    my $correlations;
    while (defined $fh and $line = <$fh> and $line !~ /END QUANTO CORRELATIONS/) {
        $line =~ s/(\r|\n)+//g;
        my @correls = split(',', $line);
        my $days    = $correls[0];
        my $values  = $correls[1];
        $correlations->{$days} = $values;
    }

    return $correlations;
}

sub read_interest_rates {
    my ($self, $fh, $data) = @_;

    my $line = <$fh>;
    if ($line !~ /ATM/i) {
        die("Wrong file format [$line]");
    }
    $line =~ s/(\r|\n)+//g;
    my @keys = split(/,/, $line);

    my $start_date = Date::Utility->new($data->{'date'});
    my $term_structure;
    my $previous_dvd_point = 0;
    while (defined $fh and $line = <$fh> and $line !~ /END TERM STRUCTURE STANDARD DATES\s?([A-Z]+)?/) {
        $line =~ s/(\r|\n)+//g;
        if ($line =~ /^(\d+-\w+-\d+)/) {
            my $date   = $1;
            my @values = split(/,/, $line);
            #Possible duplicates will be ignored
            my $days_between;
            eval { $days_between = Date::Utility->new($date)->days_between($start_date); };    ## no critic (Eval)
            if (exists $term_structure->{$days_between}) { next; }
            my $r_rate = 0;
            for (my $i = 0; $i < 8; $i++) {

                if ($keys[$i + 1] =~ /Funding/i) {
                    $r_rate = $values[$i + 1];
                }
            }
            $term_structure->{$days_between} = $r_rate;
        }
    }

    return $term_structure;
}

sub read_vol_spread_lines {
    my ($self, $fh) = @_;

    #skip the line
    my $line = <$fh>;
    if ($line !~ /^Date/i) {
        die("Wrong file format [$line]");
    }

    my $vol_spread;
    while (defined $fh and $line = <$fh> and $line !~ /END VOL SPREADS/) {
        $line =~ s/(\r|\n)+//g;
        if ($line =~ /^(\d+-\D+-\d+)/) {
            my $date   = $1;
            my @values = split(/,/, $line);
            $vol_spread->{$values[1]} = $values[2];
        }
    }

    return $vol_spread;
}

sub read_bets_single_barrier_lines {
    my ($self, $fh, $bet_type, $ending_line) = @_;

    #skip the line
    my $line = <$fh>;

    my @bet;
    while (defined $fh and $line = <$fh> and $line !~ /$ending_line/) {
        $line =~ s/(\r|\n)+//g;
        my @values = split(/,/, $line);
        if ($values[1] =~ /(\d{1,2})\/(\d{1,2})\/(\d{4})/) {
            my $month = length($1) == 1 ? '0' . $1 : $1;
            my $day   = length($2) == 1 ? '0' . $2 : $2;
            $values[1] = $3 . '-' . $month . '-' . $day;
        }
        push @bet,
            {
            'barrier'  => $values[0],
            'barrier2' => 0,
            'expiry'   => $values[1],
            'mid'      => $values[2],
            ID         => $values[3],
            mini       => $values[4],
            'bet_type' => $bet_type,
            };
    }

    return \@bet;
}

sub read_bets_double_barrier_lines {
    my ($self, $fh, $bet_type, $ending_line) = @_;

    #skip the line
    my $line = <$fh>;

    my @bet;
    while (defined $fh and $line = <$fh> and $line !~ /$ending_line/) {
        $line =~ s/(\r|\n)+//g;
        my @values = split(/,/, $line);
        if ($values[3] !~ /(\d|\-|\+|\.)+/) { next; }
        if ($values[1] =~ /(\d{1,2})\/(\d{1,2})\/(\d{4})/) {
            my $month = length($1) == 1 ? '0' . $1 : $1;
            my $day   = length($2) == 1 ? '0' . $2 : $2;
            $values[1] = $3 . '-' . $month . '-' . $day;
        }
        push @bet,
            {
            'barrier'  => $values[2],
            'expiry'   => $values[1],
            'barrier2' => $values[0],
            'mid'      => $values[3],
            ID         => $values[4],
            mini       => $values[5],
            'bet_type' => $bet_type,
            };
    }

    return \@bet;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
