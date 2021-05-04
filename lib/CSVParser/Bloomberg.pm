package CSVParser::Bloomberg;

=head1 NAME

CSVParser::Bloomberg

=head1 DESCRIPTION

This class represents a bloomberg contract that we use in pricing QA.

This module is supposed to QA our prices in bloomberg using OVRA, OSA or MARS tools.

my $table = CSVParser::Bloomberg->new();
print $table->line;

NOTE: For expiry_date if it was a non trading day the next trading day will be automatically used.

NOTE: all exported_XXXX subs are related to processing thre OVRA exported CSV files for repricing the bets in our system.
=head1 ATTRIBUTES

=cut

use Moose;
use Date::Parse;
use Text::CSV;
use CGI;
use BOM::Product::ContractFactory qw( produce_contract );
use SetupDatasetTestFixture;
use Date::Utility;
use BOM::MarketData::Fetcher::VolSurface;
use VolSurface::Utils qw(get_strike_for_spot_delta);
use BOM::MarketData qw(create_underlying);
use Try::Tiny;
use Postgres::FeedDB::Spot::Tick;
use YAML::CacheLoader qw(LoadFile);

sub max_number_of_uploadable_rows {
    return 2000000;
}

#BOM bet type.
has 'bet' => (
    is         => 'rw',
    isa        => 'Maybe[BOM::Product::Contract]',
    lazy_build => 1,
);

has 'r' => (
    is  => 'rw',
    isa => 'Maybe[Num]',
);

has 'q' => (
    is  => 'rw',
    isa => 'Maybe[Num]',
);

#BOM bet type.
has 'bet_type' => (
    is  => 'rw',
    isa => 'Str',
);

has 'date_pricing' => (
    is  => 'rw',
    isa => 'Date::Utility',
);

has 'date_start' => (
    is  => 'rw',
    isa => 'Date::Utility',
);

has 'expiry_date_bom' => (
    is  => 'rw',
    isa => 'Date::Utility',
);

has 'id' => (
    is  => 'rw',
    isa => 'Str',
);

#This is the portfolio name in bloomberg
has 'portfolio' => (
    is  => 'rw',
    isa => 'Str',
);

has 'payout_currency' => (
    is  => 'rw',
    isa => 'Str',
);

has 'payout_amount' => (
    is      => 'rw',
    isa     => 'Num',
    default => 100,
);

has 'underlying_symbol' => (
    is  => 'rw',
    isa => 'Str',
);

has 'current_spot' => (
    is  => 'rw',
    isa => 'Num',

);

has 'underlying' => (
    is         => 'rw',
    isa        => 'Quant::Framework::Underlying',
    lazy_build => 1,
);

has 'cut_off_time' => (
    is  => 'rw',
    isa => 'Str',
);

has 'price_type' => (
    is  => 'rw',
    isa => 'Str',
);

#This could be theo, bid or ask based on price_type param
has 'price' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

has 'theo_prob' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

#higher barrier or the main barrier
has 'high_barrier' => (
    is  => 'rw',
    isa => 'Num',
);

#lower barrier in two barrier bets
has 'low_barrier' => (
    is  => 'rw',
    isa => 'Maybe[Num]',
);

has 'barrier' => (
    is  => 'rw',
    isa => 'Maybe[Num]',
);

has 'spot' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_spot {
    my $self = shift;

    return $self->current_spot;
}

has 'barrier_type' => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

has 'premium_adjusted' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

# This is the field we get from the exported from in OVRA
# We put it here as an easy way to compare our price with bloomberg.
has 'bloomberg_exported_price_mid' => (
    is      => 'rw',
    isa     => 'Num',
    default => 0,
);

# This is the field we get from the exported from in OVRA
# We put it here as an easy way to inspect the problems in our price.
has 'bloomberg_exported_error_mid' => (
    is      => 'rw',
    isa     => 'Num',
    default => 0,
);

sub _get_value {
    my $self           = shift;
    my $attribute_name = shift;
    my $default_value  = shift;

    my $q = CGI->new;
    if ($q->param($attribute_name)) {
        if (wantarray()) {
            return [$q->param($attribute_name)];
        } else {
            return $q->param($attribute_name);
        }
    }

    return $default_value;
}

#UI = Up and In, DI = Down and In, DO = Down and out, UO = Up and out
sub _build_barrier_type {
    my $self = shift;
    if ($self->bet_type eq 'ONETOUCH' or $self->bet_type eq 'NOTOUCH') {
        if ($self->barrier > $self->spot) {
            return 'UO';
        } else {
            return 'DO';
        }
    } else {
        return '';
    }
}

has 'volsurface' => (
    is      => 'rw',
    isa     => 'Maybe[Quant::Framework::VolSurface::Delta]',
    default => undef
);

sub _build_bet {
    my $self     = shift;
    my $bet_args = {
        underlying                => $self->underlying,
        current_spot              => $self->spot,
        bet_type                  => $self->bet_type,
        date_start                => $self->date_start,
        date_expiry               => $self->expiry_date_bom,
        payout                    => $self->payout_amount,
        currency                  => $self->payout_currency,
        date_pricing              => $self->date_pricing,
        q_rate                    => $self->q,
        r_rate                    => $self->r,
        uses_empirical_volatility => 0,
    };
    if ($self->_get_bet_type_bloomberg eq 'DNT' or $self->_get_bet_type_bloomberg eq 'DOT') {
        $bet_args->{high_barrier} = $self->high_barrier;
        $bet_args->{low_barrier}  = $self->low_barrier;
    } else {
        $bet_args->{barrier} = $self->barrier;
    }

    $bet_args->{volsurface}   = $self->volsurface;
    $bet_args->{current_tick} = Postgres::FeedDB::Spot::Tick->new(
        underlying => $bet_args->{underlying}->symbol,
        quote      => $bet_args->{current_spot},
        epoch      => $bet_args->{date_start}->epoch,
    );
    my $bet = produce_contract($bet_args);
    return $bet;
}

sub _build_premium_adjusted {
    my $self = shift;
    return $self->underlying->{market_convention}->{delta_premium_adjusted};
}

sub _build_price {
    my $self = shift;
    my $price;
    if ($self->price_type eq 'none') {
        $price = 0;
    } elsif ($self->price_type eq 'ask') {
        $price = $self->bet->ask_price;
    } elsif ($self->price_type eq 'bid') {
        $price = $self->bet->bid_price;
    } elsif ($self->price_type eq 'theo') {
        $price = $self->theo_prob * $self->bet->payout;
    }

    #this is for VV engine
    #if (price_type eq 'VV')
    return sprintf("%.2f", $price);
}

sub _build_theo_prob {
    my $self = shift;
    my $bet  = $self->bet;
    my $theo =
        $bet->pricing_engine->can('_base_probability') ? $bet->pricing_engine->_base_probability : $bet->pricing_engine->base_probability->amount;

    return $theo;
}

sub _build_underlying {
    my $self = shift;
    return create_underlying($self->underlying_symbol);
}

# this field is for European Digitals and specifies whether it is a FOR/DOM digital CALL/PUT
sub _get_Ccy_P_C {
    my $self = shift;

    my $foreign;
    if ($self->underlying_symbol =~ /frx([A-Z]{3})[A-Z]{3}/) {
        $foreign = $1;
    }
    if ($self->bet_type eq 'CALL' or $self->bet_type eq 'DOUBLEUP') {
        return $foreign . ' Call';
    } elsif ($self->bet_type eq 'PUT' or $self->bet_type eq 'DOUBLEDOWN') {
        return $foreign . ' Put';
    } else {
        return '';
    }
}

sub _get_strike_bloomberg {
    my $self = shift;

    if ($self->_get_bet_type_bloomberg eq 'Digital') {
        return sprintf("%.5f", $self->barrier);
    }

}

sub _get_high_barrier_bloomberg {
    my $self = shift;

    if ($self->high_barrier) {
        return sprintf("%.5f", $self->high_barrier);
    }
    return '';
}

sub _get_low_barrier_bloomberg {
    my $self = shift;
    if (   $self->_get_bet_type_bloomberg eq 'DNT'
        or $self->_get_bet_type_bloomberg eq 'DOT')
    {
        return sprintf("%.5f", $self->low_barrier);
    }
    return '';
}

sub _get_underlying_bloomberg {
    my $self       = shift;
    my $underlying = $self->underlying_symbol;
    $underlying =~ s/^frx//;
    return $underlying;
}

sub _get_bet_type_bloomberg {
    my $self  = shift;
    my $types = {
        'ONETOUCH'   => 'OT',
        'NOTOUCH'    => 'NT',
        'RANGE'      => 'DNT',
        'UPORDOWN'   => 'DOT',
        'CALL'       => 'Digital',
        'PUT'        => 'Digital',
        'DOUBLEUP'   => 'Digital',
        'DOUBLEDOWN' => 'Digital',
    };
    return $types->{$self->bet_type};
}

sub _get_expiry_date_bloomberg {
    my $self = shift;
    return $self->expiry_date_bom->month . '/' . $self->expiry_date_bom->day_of_month . '/' . $self->expiry_date_bom->year;
}

sub _get_delivery_date_bloomberg {
    my $self          = shift;
    my $delivery_date = Date::Utility->new($self->expiry_date_bom->epoch + 86400);
    if (!$self->underlying->calendar->trades_on($self->underlying->exchange, $delivery_date)) {
        $delivery_date = $self->underlying->calendar->trade_date_after($self->underlying->exchange, $delivery_date);
    }
    return $delivery_date->month . '/' . $delivery_date->day_of_month . '/' . $delivery_date->year;
}

sub _get_trade_date_bloomberg {
    my $self = shift;
    my $now  = $self->date_start;
    return $now->month . '/' . $now->day_of_month . '/' . $now->year;
}

sub _get_premium_date_bloomberg {
    my $self = shift;
    my $now  = $self->date_start;
    return $now->month . '/' . $now->day_of_month . '/' . $now->year;
}

sub _get_notes {
    my $self = shift;
    return
          'de='
        . sprintf("%.3f", $self->bet->delta) . ' ga='
        . sprintf("%.3f", $self->bet->gamma) . ' ve='
        . sprintf("%.3f", $self->bet->vega) . ' va='
        . sprintf("%.3f", $self->bet->vanna) . ' vol='
        . sprintf("%.3f", $self->bet->volga)
        . ' avol='
        . sprintf("%.3f", $self->bet->_pricing_args->{iv}) . ' tv=';
}

sub get_csv_line {
    my $self   = shift;
    my $fields = shift;
    my $header = shift;

    my $line = $self->id . ',';

    $line .=
          $self->portfolio . ','
        . $self->_get_trade_date_bloomberg . ','
        . $self->_get_premium_date_bloomberg . ',' . "Buy" . ','
        . $self->_get_bet_type_bloomberg . ',';
    $line .=
          "" . ','
        . $self->_get_underlying_bloomberg . ','
        . $self->_get_Ccy_P_C . ','
        . $self->_get_expiry_date_bloomberg . ','
        . $self->_get_delivery_date_bloomberg . ','
        . $self->_get_strike_bloomberg . ',';
    $line .=
          $self->payout_currency . ','
        . $self->payout_amount . ',' . "" . ',' . "" . ','
        . $self->_get_high_barrier_bloomberg . ','
        . $self->_build_barrier_type . ',';
    $line .=
          $self->_get_low_barrier_bloomberg . ','
        . (-1 * $self->price) . ','
        . $self->payout_currency
        . ',Cash '
        . $self->payout_currency . ',' . "Gmt" . ',';
    $line .= $self->cut_off_time . ',';

    my ($base_numeraire, $bb_tv);
    $self->_get_underlying_bloomberg =~ /(\w{3})(\w{3})/;
    if ($self->payout_currency eq $1) {
        $base_numeraire = 'base';
        $bb_tv          = $fields->[$header->{'Theo. Value Ccy1'}] / 100;
    } elsif ($self->payout_currency eq $2) {
        $base_numeraire = 'numeraire';
        $bb_tv          = $fields->[$header->{'Theo. Value Ccy2'}] / 100;
    }
    $line .=
          $base_numeraire . ','
        . $self->bet->_pricing_args->{spot} . ','
        . $self->bet->_pricing_args->{iv} . ','
        . ($fields->[$header->{'Volatility'}] / 100) . ','
        . abs($self->bet->_pricing_args->{iv} - $fields->[$header->{'Volatility'}] / 100) . ','
        . $self->bet->timeinyears->amount . ','
        . $self->bet->timeinyears->amount * 365 . ','
        . $self->r . ','
        . $self->q;
    $line .= ',' . $self->_get_notes;
    $line .= ',' . $self->date_pricing->datetime_yyyymmdd_hhmmss_TZ;
    $line .= ',' . $self->bet->bid_probability->amount;
    $line .= ',' . $self->bet->ask_probability->amount;
    $line .= ',' . ($self->bet->ask_probability->amount - $self->bet->bid_probability->amount);
    $line .= ',' . $self->theo_prob;
    $line .= ',' . $self->bloomberg_exported_price_mid / 100;
    $line .= ',' . abs(sprintf("%.4f", $self->theo_prob) - $self->bloomberg_exported_price_mid / 100);
    return $line;
}

sub get_csv_header {
    return
          "External ID#,Portfolio,Trade Date: MM/DD/YYYY,Premium Date: MM/DD/YYYY,B/S,Type,On Shore,Currency Pair,"
        . "Ccy+P/C,Expiration Date: MM/DD/YYYY,Delivery Date: MM/DD/YYYY,Strike,Notional Currency,Notional Amount,"
        . "Strike 2,Notional Amount 2,Barrier,Barrier Type,Barrier 2,Premium Amount,Premium Currency,Settlement Type,"
        . "ZoneId,Cut Time,base/numeraire,bom_spot,bom_atm,bb_atm,error_atm,bom_time_in_year,bom_time_in_days,"
        . "bom_r,bom_q,Notes,date_pricing,bom_bid,bom_ask,bom_spread,bom_mid,bb_mid,error_mid";
}

sub exported_field_headers {
    my $lines = shift;
    my $csv   = Text::CSV->new({binary => 1});
    if (not $csv->parse($lines->[0])) {
        die('Unable to parge line ' . $lines->[0]);
    }
    my @fields = $csv->fields();

    my $field_hash;
    my $count = 0;
    foreach my $field (@fields) {

        #Skip the second column that is empty
        if ($field eq '') {
            next;
        }
        $field_hash->{$field} = $count;
        $count++;
    }
    return $field_hash;
}

sub exported_field_headers_adding_bom_for_output {
    my $lines = shift;
    my $csv   = Text::CSV->new({binary => 1});
    if (not $csv->parse($lines->[0])) {
        die('Unable to parse line ' . $lines->[0]);
    }
    my @fields = $csv->fields();

    my $field_line = '';
    foreach my $field (@fields) {
        if ($field ne '') {
            $field_line .= 'input_' . $field . ',';
        }
    }
    $field_line =~ s/(,)$//;
    return $field_line;
}

sub clean_the_content {
    my $lines = shift;
    my @clean_content;
    foreach my $line (@{$lines}) {
        my @fields = split(',', $line);
        if (   $fields[0] =~ /:/
            or $fields[0] =~ /-/
            or $fields[0] =~ /Filters/i
            or $fields[0] =~ /Total/i)
        {
            next;
        }

        #remove the extra empty column (second column)
        $line =~ s/^([^,]*,)(,)/$1/;
        push @clean_content, $line;
    }
    return \@clean_content;
}

sub exported_pricing_date {
    my $lines = shift;

    #Last line of the file should have a line like this
    #Pricing Date: Fri Jan 20 2012 14:18
    if ($lines->[scalar @{$lines} - 1] =~ /Pricing Date:(.*)/) {
        return Date::Utility->new(Date::Parse::str2time($1));
    } else {
        die 'Unable to parse the pricing date from last line ' . Data::Dumper::Dumper($lines);
    }
}

sub exported_bet_type {
    my $line   = shift;
    my $fields = shift;
    if (    $line->[$fields->{'Style'}] eq 'Digital'
        and $line->[$fields->{'P/C'}] eq 'C')
    {
        return 'CALL';
    }
    if (    $line->[$fields->{'Style'}] eq 'Digital'
        and $line->[$fields->{'P/C'}] eq 'P')
    {
        return 'PUT';
    }
    if ($line->[$fields->{'Style'}] eq 'Double NT') {
        return 'RANGE';
    }
    if ($line->[$fields->{'Style'}] eq 'Double OT') {
        return 'UPORDOWN';
    }
    if ($line->[$fields->{'Style'}] eq 'No touch') {
        return 'NOTOUCH';
    }
    if ($line->[$fields->{'Style'}] eq 'One touch') {
        return 'ONETOUCH';
    }
    return;
}

sub exported_payout_currency {
    my $line   = shift;
    my $fields = shift;
    return $line->[$fields->{'Prem Ccy'}];
}

sub exported_underlying_symbol {
    my $line   = shift;
    my $fields = shift;
    return 'frx' . $line->[$fields->{'Ccy Pair'}];
}

sub exported_high_barrier {
    my $line   = shift;
    my $fields = shift;

    my @range_bet = ('Double NT', 'Double OT', 'No touch', 'One touch');
    if (grep { $line->[$fields->{'Style'}] eq $_ } @range_bet) {
        return $line->[$fields->{'Barrier1'}];
    } else {
        return $line->[$fields->{'Strike'}];
    }
}

sub exported_low_barrier {
    my $line   = shift;
    my $fields = shift;
    if (   $line->[$fields->{'Style'}] eq 'Double NT'
        or $line->[$fields->{'Style'}] eq 'Double OT')
    {
        return $line->[$fields->{'Barrier2'}];
    }
    return 0;
}

sub exported_cut_off_time {
    my $line   = shift;
    my $fields = shift;
    if ($line->[$fields->{'Cut'}] =~ /GMT\s(\d+\:\d+)/) {
        return $1;
    }
    return;
}

sub exported_spot {
    my $line   = shift;
    my $fields = shift;
    return $line->[$fields->{'Spot'}];
}

sub get_mini {
    my $line   = shift;
    my $fields = shift;

    return $line->[$fields->{mini}];
}

sub exported_external_id {
    my $line   = shift;
    my $fields = shift;
    return $line->[$fields->{'External ID'}];
}

sub exported_bloomberg_price_mid {
    my $line   = shift;
    my $fields = shift;
    my $price;
    if (
        not defined $line->[$fields->{'Option Price % Ccy1'}]
        or (defined $line->[$fields->{'Option Price % Ccy1'}]
            and $line->[$fields->{'Option Price % Ccy1'}] eq ''))
    {
        $price = $line->[$fields->{'Option Price % Ccy2'}];
    } else {
        $price = $line->[$fields->{'Option Price % Ccy1'}];
    }

    #Some numbers in the file has virgule.
    $price =~ s/,//g;
    return $price;
}

sub exported_r_rate {
    my $line   = shift;
    my $fields = shift;
    return $line->[$fields->{'Depo Ccy2'}];
}

sub exported_q_rate {
    my $line   = shift;
    my $fields = shift;
    return $line->[$fields->{'Depo Ccy1'}];
}

sub export_date_expiry {
    my $line        = shift;
    my $fields      = shift;
    my $expiry_date = $line->[$fields->{'Expiry Date'}];
    my $cut_time    = $line->[$fields->{'Cut'}];
    $cut_time =~ s/GMT\s(\d+\:\d+)/ $1 GMT/;
    return Date::Utility->new(Date::Parse::str2time($expiry_date . $cut_time));
}

has 'config' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_config {
    my $self       = shift;
    my $config_loc = "/home/git/regentmarkets/bom-quant-benchmark/t/config.yml";
    die unless $config_loc;
    my $config = LoadFile($config_loc);
    return $config;
}

sub get_volsurface {
    my ($self, $underlying_symbol) = @_;

    my $data    = $self->config->{volsurface}->{$underlying_symbol};
    my $surface = Quant::Framework::VolSurface::Delta->new(
        underlying       => create_underlying($underlying_symbol),
        creation_date    => Date::Utility->new($data->{creation_date}),
        surface          => $data->{surface_data},
        print_precision  => undef,
        cutoff           => $data->{cutoff},
        deltas           => [25, 50, 75],
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
    );

    return $surface;
}

# This sub will read the uploaded csv and price the bets and output a new csv for more inspections.
sub price_list {
    my ($self, $line_ref, $mini) = @_;

    my @lines;
    if ($line_ref) {
        @lines = @{$line_ref};
    } else {
        my $q  = CGI->new;
        my $fh = $q->upload('file');
        @lines = <$fh>;
    }

    my $headers      = exported_field_headers(\@lines);
    my $pricing_date = exported_pricing_date(\@lines);

    my $cleaned_lines = clean_the_content(\@lines);
    my $csv_header    = get_csv_header() . "\n";

    my $content;
    for (my $i = 1; $i < scalar @{$cleaned_lines}; $i++) {
        my $contract;
        my $line = $cleaned_lines->[$i];
        my $csv  = Text::CSV->new({binary => 1});
        if (not $csv->parse($line)) {
            die('Unable to parse line ' . $line);
        }
        chomp($line);
        my @fields          = $csv->fields();
        my $expiry_date_bom = export_date_expiry(\@fields, $headers);
        my $r_rate          = exported_r_rate(\@fields, $headers);
        my $q_rate          = exported_q_rate(\@fields, $headers);

        if ($mini eq 'mini') {
            next
                if not get_mini(\@fields, $headers);
        }

        if ($expiry_date_bom->epoch <= $pricing_date->epoch) {
            next;
        }

        my $underlying_symbol = exported_underlying_symbol(\@fields, $headers);
        my $contract_args     = {
            id                           => exported_external_id(\@fields, $headers),
            bet_type                     => exported_bet_type(\@fields, $headers),
            payout_currency              => exported_payout_currency(\@fields, $headers),
            underlying_symbol            => $underlying_symbol,
            cut_off_time                 => exported_cut_off_time(\@fields, $headers),
            price_type                   => 'theo',
            portfolio                    => 'Reprice',
            current_spot                 => exported_spot(\@fields, $headers),
            date_start                   => $pricing_date,
            expiry_date_bom              => $expiry_date_bom,
            date_pricing                 => $pricing_date,
            bloomberg_exported_price_mid => exported_bloomberg_price_mid(\@fields, $headers),
            r                            => $r_rate / 100,
            q                            => $q_rate / 100,
            payout_amount                => 100,
        };
        if ($contract_args->{bet_type} eq 'RANGE' or $contract_args->{bet_type} eq 'UPORDOWN') {
            $contract_args->{high_barrier} = exported_high_barrier(\@fields, $headers);
            $contract_args->{low_barrier}  = exported_low_barrier(\@fields, $headers);
        } else {
            $contract_args->{barrier} = exported_high_barrier(\@fields, $headers);
        }
        my $underlying            = create_underlying($underlying_symbol);
        my $interest_rates_config = _get_interest_rate_data();

        my $rate = {
            asset_rate           => {continuous => $interest_rates_config->{$underlying->asset_symbol}},
            quoted_currency_rate => $interest_rates_config->{$underlying->quoted_currency_symbol},
        };

        my $fixture = SetupDatasetTestFixture->new;
        $fixture->setup_test_fixture({
            underlying => $underlying,
            rates      => $rate,
            date       => $pricing_date
        });
        $contract_args->{volsurface} = $self->get_volsurface($underlying_symbol);
        try {
            $contract = CSVParser::Bloomberg->new($contract_args);
            $content .= $contract->get_csv_line(\@fields, $headers) . "\n";
        } catch {
            print "not able to process line[$line] $_\n";
        };
    }
    return ($csv_header, $content);
}

sub _get_interest_rate_data {
    my $file_path = '/home/git/regentmarkets/bom-quant-benchmark/t/csv/interest_rates.csv';
    my $csv       = Text::CSV->new({sep_char => ','});
    open(my $data, '<', $file_path) or die "Could not open '$file_path' $!\n";    ## no critic (RequireBriefOpen)
    my $rates;
    while (my $line = <$data>) {
        chomp $line;

        if ($csv->parse($line)) {
            my @fields = $csv->fields();

            my $symbol = $fields[0];

            for (my $i = 1; $i < scalar @fields; $i += 2) {
                my $tenor = $fields[$i];
                my $rate  = $fields[$i + 1];

                $rates->{$symbol}->{$tenor} = $rate;
            }
        }
    }

    return $rates;
}

__PACKAGE__->meta->make_immutable;
1;
