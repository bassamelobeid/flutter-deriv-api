package CSVParser::Superderivatives_FX;

use Moose;

use Path::Tiny;
use Text::CSV::Slurp;
use List::Util qw(first);
use Carp;
use Math::Business::BlackScholesMerton::NonBinaries;

use VolSurface::Utils qw(get_2vol_butterfly);
use BOM::MarketData qw(create_underlying);
use BOM::Product::ContractFactory qw( produce_contract );
use SetupDatasetTestFixture;
use BOM::Test::Data::Utility::FeedTestDatabase;
use Date::Utility;
use Data::Dumper;

has file => (
    is       => 'ro',
    isa      => 'Str',
    required => 1
);

has suite => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
);

has records => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_records {
    my $self = shift;

    my @lines      = path($self->file)->lines;
    my $rate_lines = $self->_get_lines_between([@lines], 'START RATES', 'END RATES');
    my $rate       = $self->_get_rates($rate_lines);
    my $vol_lines  = $self->_get_lines_between([@lines], 'START VOL', 'END VOL');
    my $data       = $self->_get_lines_between([@lines], 'START PRICES', 'END PRICES');
    my $hr         = $self->_convert_to_array_of_hashes($data);

    my @base_dataset = @$hr;
    @base_dataset = grep { $_->{mini} } @base_dataset if $self->suite eq 'mini';

    my @numeraire_dataset;
    foreach my $type (qw(CALL PUT ONETOUCH)) {
        my @new_set = grep { $self->_get_bet_type({option_class => $_->{OptionClass}, call_put => $_->{'Call/Put'}}) eq $type } @base_dataset;
        push @numeraire_dataset, @new_set;
    }
    my $date_start        = Date::Utility->new(_get_start_datetime([@lines]));
    my $underlying_symbol = _get_symbol(\@lines);
    my $underlying        = create_underlying($underlying_symbol);
    my $spot              = _get_spot(\@lines);
    my $payout            = 100;

    my $fixture = SetupDatasetTestFixture->new();
    $fixture->setup_test_fixture({
        underlying => $underlying,
        rates      => $rate,
        spot       => $spot,
        date       => $date_start
    });

    my $surface_data = $self->_get_surface_data($vol_lines, $underlying, $spot, $rate);

    BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick({
        underlying => $underlying->symbol,
        epoch      => $date_start->epoch,
        quote      => $spot,
    });

    my $surface = Quant::Framework::VolSurface::Delta->new(
        underlying       => $underlying,
        creation_date    => $date_start,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        surface          => $surface_data,
        cutoff           => 'New York 10:00',
        deltas           => [25, 50, 75],
    );

    my $record_param = {
        spot       => $spot,
        underlying => $underlying,
        payout     => $payout,
        date_start => $date_start,
        volsurface => $surface,
    };

    my $numeraire_records = $self->_get_records_for(\@numeraire_dataset, 'numeraire', $record_param);
    my $base_records      = $self->_get_records_for(\@base_dataset,      'base',      $record_param);

    return {
        base_records      => $base_records,
        numeraire_records => $numeraire_records,
    };
}

sub _get_records_for {
    my ($self, $records, $base_or_num, $record_param) = @_;

    my $underlying = $record_param->{underlying};
    my $spot       = $record_param->{spot};
    my $payout     = $record_param->{payout};
    my $date_start = $record_param->{date_start};
    my $surface    = $record_param->{volsurface};

    my @all_records;
    foreach my $record (@$records) {
        my $date_expiry = Date::Utility->new($record->{ExpiryDate});
        next if $date_expiry->days_between($date_start) > 365;
        my $barrier  = $record->{StrikePrice} || $record->{Barrier1};
        my $barrier2 = $record->{Barrier2}    || 0;
        my $bet_type = $self->_get_bet_type({
                option_class => $record->{OptionClass},
                call_put     => $record->{'Call/Put'}});
        if ($bet_type eq "RANGE" or $bet_type eq "UPORDOWN") {
            my $swap_barrier = $barrier;
            $barrier  = $barrier2;
            $barrier2 = $swap_barrier;
            next if ($spot <= $barrier2 or $spot >= $barrier);
        }

        if ($bet_type eq 'ONETOUCH' or $bet_type eq 'NOTOUCH') {
            next if ($barrier == $spot);
        }

        my $numeraire_currency = $record->{TermCurrency};
        my $base_currency      = $record->{BaseCurrency};
        my $date_pricing       = $date_start;
        my $sd_bid             = $record->{PriceBid};
        my $sd_ask             = $record->{PriceOffer};
        my $sd_mid             = $record->{PriceMid};
        my $days_between       = $date_expiry->days_between($date_start);
        my $tiy                = $days_between / 365;

        if ($base_or_num eq 'numeraire') {
            my %conversion_param = (
                underlying    => $underlying,
                barrier       => $barrier,
                barrier2      => $barrier2,
                date_start    => $date_start,
                date_expiry   => $date_expiry,
                volsurface    => $surface,
                payout        => $payout,
                currency      => $base_currency,
                date_pricing  => $date_start,
                spot          => $spot,
                time_in_years => $tiy,
                bet_type      => $bet_type,
                initial_mid   => $record->{PriceMid},
            );
            $sd_mid = _convert_sd_mid_to_numeraire(\%conversion_param);
        }

        my $params = {
            underlying         => $underlying,
            date_start         => $date_start,
            date_expiry        => $date_expiry,
            volsurface         => $surface,
            payout             => $payout,
            date_pricing       => $date_pricing,
            spot               => $spot,
            bet_type           => $bet_type,
            barrier            => $barrier,
            barrier2           => $barrier2,
            sd_ask             => $sd_ask,
            sd_bid             => $sd_bid,
            sd_mid             => $sd_mid,
            base_currency      => $base_currency,
            numeraire_currency => $numeraire_currency,
            date_pricing       => $date_pricing,
            ID                 => $record->{ID},
            premium_adjusted   => $underlying->market_convention->{delta_premium_adjusted},
            strike_price       => $record->{StrikePrice},
        };
        push @all_records, $params;
    }

    return \@all_records;
}

sub _convert_sd_mid_to_numeraire {
    my $args = shift;

    my $underlying     = $args->{underlying};
    my $spot           = $args->{spot};
    my $tiy            = $args->{time_in_years};
    my $barrier        = $args->{barrier};
    my $bet_type       = $args->{bet_type};
    my $initial_sd_mid = $args->{initial_mid};

    my %pricing_param = (
        underlying                => $underlying,
        barrier                   => $barrier,
        barrier2                  => $args->{barrier2},
        date_start                => $args->{date_start},
        date_expiry               => $args->{date_expiry},
        volsurface                => $args->{volsurface}->clone(),
        payout                    => $args->{payout},
        currency                  => $args->{currency},
        date_pricing              => $args->{date_start},
        uses_empirical_volatility => 0,
    );

    my $sd_mid;

    if ($bet_type eq 'CALL') {
        $pricing_param{bet_type} = 'VANILLA_CALL';
        my $compare_bet = produce_contract(\%pricing_param);
        my $compare_bet_bs =
            Math::Business::BlackScholesMerton::NonBinaries::vanilla_call($spot, $barrier, $tiy, $underlying->dividend_rate_for($tiy),
            $compare_bet->mu, $compare_bet->vol_at_strike);
        $sd_mid = ($initial_sd_mid * $spot - $compare_bet_bs) / $barrier;
    } elsif ($bet_type eq 'PUT') {
        $pricing_param{bet_type} = 'VANILLA_PUT';
        my $compare_bet    = produce_contract(\%pricing_param);
        my $compare_bet_bs = Math::Business::BlackScholesMerton::NonBinaries::vanilla_put($spot, $barrier, $tiy, $underlying->dividend_rate_for($tiy),
            $compare_bet->mu, $compare_bet->vol_at_strike);
        $sd_mid = ($initial_sd_mid * $spot + $compare_bet_bs) / $barrier;
    } elsif ($bet_type eq 'ONETOUCH') {
        $sd_mid = $initial_sd_mid * $spot / $barrier;
    } else {
        croak 'Trying to convert unknown bet_type[' . $bet_type . '] to numeraire';
    }

    return $sd_mid;
}

sub _get_lines_between {
    my ($self, $line_array, $start, $end) = @_;

    my @lines = @$line_array;
    my @wanted;
    foreach (@lines) {
        chomp;
        if (/^$start/ .. /^$end/) {
            next if /^($start|$end)/;
            s/(,,$|\s)//g;    #removes empty column and irritating whitespace!
            push @wanted, [split ',', $_];
        }
    }
    return [@wanted];
}

sub _get_rates {
    my ($self, $rate_lines) = @_;

    my $t_rates     = $self->_transpose($rate_lines);                 # we need to do this. If not I will go crazy trying to calculate interest rates
    my $t_rates_ref = $self->_convert_to_array_of_hashes($t_rates);
    $self->_removes_brackets($t_rates_ref);

    my %asset_rate;
    my %quoted_currency_rate;

    foreach my $rate (@$t_rates_ref) {
        my $day = $self->_get_day_in_number($rate->{Col_names});
        my $t   = $day / 365;
        $asset_rate{$day}           = -log(1 / (1 + ($rate->{DepoBase} / 100 * $t))) / $t * 100;
        $quoted_currency_rate{$day} = -log(1 / (1 + ($rate->{DepoTerm} / 100 * $t))) / $t * 100;
    }

    return {
        asset_rate           => {continuous => \%asset_rate},
        quoted_currency_rate => \%quoted_currency_rate,
    };
}

sub _transpose {
    my ($self, $in) = @_;

    my $cols = scalar(@{$in->[0]}) || 0;
    my @out  = ();
    foreach my $col (0 .. $cols - 1) {
        push @out, [map { $_->[$col] } @$in];
    }
    return wantarray ? @out : [@out];
}

sub _convert_to_array_of_hashes {
    my ($self, $wanted) = @_;

    my @wanted         = @$wanted;
    my @wanted_strings = map { join ',', @$_ } @wanted;

    my $wanted_string = join "\n", @wanted_strings;
    my $ar_of_hr      = Text::CSV::Slurp->load(string => $wanted_string);

    return $ar_of_hr;
}

sub _removes_brackets {
    my ($self, $args) = @_;

    foreach my $data (@$args) {
        foreach my $num (values %$data) {
            next if !defined $num;
            if ($num =~ /^\s?\(\d+\.\d+\)\s?$/) {
                $num =~ s/(\s|\(|\))//g;     # negative numbers in excel are in brackets!!!
                $num =~ s/(\d+\.\d+)/-$1/;
            }
        }
    }
}

sub _get_day_in_number {
    my ($self, $dis) = @_;
    my %multiplier = (
        Day   => 1,
        Month => 30,
        Year  => 365,
        Week  => 7
    );
    my ($num, $string) = $dis =~ /^(\d+)([a-zA-Z]*)$/;
    $string =~ s/s$// if $string =~ /(Month|Year|Week|Day)s/;
    return $num * $multiplier{$string};
}

sub _get_start_datetime {
    my $lines = shift;

    my @lines     = @$lines;
    my $date_line = first { $_ =~ /^DATE/ } @lines;
    my ($date)    = $date_line =~ /^DATE,(\d\d?-\w{3}-\d\d)/;
    my $time_line = first { $_ =~ /^TIME/ } @lines;
    my ($time)    = $time_line =~ /^TIME,(\d{2}:\d{2}:\d{2})\s+GMT/;

    return $date . " " . $time;

}

sub _get_symbol {
    my $lines = shift;

    my $symbol;
    foreach my $line (@$lines) {
        if ($line =~ /^CURRENCIES,(\w{3}),(\w{3})/) {
            $symbol = 'frx' . $1 . $2;
            last;
        }
    }
    return $symbol;
}

sub _get_spot {
    my $lines = shift;

    my @lines     = @$lines;
    my $spot_line = first { $_ =~ /^SPOT/ } @lines;
    my ($spot)    = $spot_line =~ /^SPOT,(\d+?\.\d+),/;

    return $spot;
}

sub _get_surface_data {
    my ($self, $vol_lines, $underlying, $spot, $rate) = @_;

    my $premium_adjusted = $underlying->market_convention->{delta_premium_adjusted};
    my $t_vol     = $self->_transpose($vol_lines);                # we need to do this. If not I will go crazy trying to calculate delta
    my $t_vol_ref = $self->_convert_to_array_of_hashes($t_vol);
    $self->_removes_brackets($t_vol_ref);

    my $deltas = $self->_calculate_vol_at_delta($t_vol_ref, $underlying, $spot);

    my $surface_data;
    foreach my $day_in_string (keys %$deltas) {
        my $days = $self->_get_day_in_number($day_in_string);
        $days = 'ON' if $days == 1;

        my $smile = {
            25 => $deltas->{$day_in_string}->{25},
            50 => $deltas->{$day_in_string}->{50},
            75 => $deltas->{$day_in_string}->{75},
        };

        $surface_data->{$days} = {
            smile      => $smile,
            vol_spread => {50 => $deltas->{$day_in_string}->{ATM_SPREAD}},
        };
    }

    return $surface_data;
}

sub _calculate_vol_at_delta {
    my ($self, $args_ref, $underlying, $spot) = @_;
    my $delta;

    foreach my $args (@$args_ref) {
        my $day    = $self->_get_day_in_number($args->{Col_names});
        my $tiy    = $day / 365;
        my $r_rate = $underlying->interest_rate_for($tiy);
        my $q_rate = $underlying->dividend_rate_for($tiy);

        my $BF_25_1_vol = $args->{'25DeltaButterfly'} / 100;
        my $BF_25_2_vol = get_2vol_butterfly(
            $spot, $tiy, .25,
            $args->{Volatility} / 100,
            $args->{'25DeltaRiskReversal'} / 100,
            $BF_25_1_vol, $r_rate, $q_rate, $underlying->market_convention->{delta_premium_adjusted}, '1_vol'
        );

        my $delta_75   = -$args->{'25DeltaRiskReversal'} / 2 + ($BF_25_2_vol * 100) + $args->{Volatility};
        my $delta_25   = $args->{'25DeltaRiskReversal'} / 2 + ($BF_25_2_vol * 100) + $args->{Volatility};
        my $delta_50   = $args->{'Volatility'};
        my $atm_spread = $args->{'VolatilitySpread'};
        $delta->{$args->{'Col_names'}}->{25}         = $delta_25 / 100;
        $delta->{$args->{'Col_names'}}->{50}         = $delta_50 / 100;
        $delta->{$args->{'Col_names'}}->{75}         = $delta_75 / 100;
        $delta->{$args->{'Col_names'}}->{ATM_SPREAD} = $atm_spread / 100;
    }

    return $delta;
}

sub _get_bet_type {
    my ($self, $args) = @_;

    my $bet_type = {
        OT  => 'ONETOUCH',
        NT  => 'NOTOUCH',
        DNT => 'RANGE',
        DOT => 'UPORDOWN',
        ED  => {
            C => 'CALL',
            P => 'PUT'
        }};
    return ($args->{option_class} ne 'ED') ? $bet_type->{$args->{option_class}} : $bet_type->{$args->{option_class}}->{$args->{call_put}};
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
