package BOM::Product::Benchmark::ContractGenerator;

=head1 NAME

BOM::Product::Benchmark::ContractGenerator

=head1 DESCRIPTION

This class will accept a set of parameters from HTML form (by default) or code and generate a list of bets with thier price in different formats.

This module is supposed to QA our prices in bloomberg using OVRA, OSA or MARS tools.

my $table = BOM::Product::Benchmark::ContractGenerator->new();
print $table->csv_table;

Because there is a limit in bloomberg for bets per upload, this module can create a json of current data and offset in the loop for already processed records.

Process:
1. Generate the options CSV from selecting the params in form.
2. Upload the CSV in OVRA.
3. Price the Bet in and export the results in a CSV file (The file must have all the fields required in exported_XXXX subs in Contract.pm)
4. Upload the exported CSV file in BO and get the new CSV file with price.

=head1 ATTRIBUTES

=cut

use Moose;
use namespace::autoclean;
use YAML::CacheLoader qw(LoadFile);
use BOM::MarketData::VolSurface::Validator;
use Template;
use Text::CSV;
use MIME::Base64;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Product::Benchmark::ContractGenerator::Bloomberg;
use BOM::Test::Data::Utility::SetupDatasetTestFixture;
use CGI;
use Try::Tiny;

has 'offset' => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

has 'portfolio' => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

has 'bet_type' => (
    is         => 'rw',
    isa        => 'ArrayRef[Str]',
    lazy_build => 1,
);

#The list that will populate the HTML form
has 'bet_type_list' => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { ['CALL', 'PUT', 'ONETOUCH', 'NOTOUCH', 'RANGE', 'UPORDOWN'] },
);

has 'maturity_days' => (
    is         => 'rw',
    isa        => 'ArrayRef[Str]',
    lazy_build => 1,
);

has 'maturity_days_list' => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    lazy    => 1,
    default => sub {
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 17, 21, 30, 40, 50, 60, 90, 120, 182, 365];
    },
);

has 'output_format' => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

#The list that will populate the HTML form
has 'output_format_list' => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { ['Bloomberg'] },
);

has 'payout_currency' => (
    is         => 'rw',
    isa        => 'ArrayRef[Str]',
    lazy_build => 1,
);

#The list that will populate the HTML form
has 'payout_currency_list' => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    lazy    => 1,
    default => sub {
        ['Base', 'Numeraire', 'AUD', 'CAD', 'CHF', 'EUR', 'GBP', 'USD', 'JPY'];
    },
);

has 'payout_amount' => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_payout_amount {
    my $self = shift;
    return $self->_get_value('payout_amount', $self->config->{payout});
}

has 'underlying_symbol' => (
    is         => 'rw',
    isa        => 'ArrayRef[Str]',
    lazy_build => 1,
);

has 'underlying_symbol_list' => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    lazy    => 1,
    default => sub {
        return [
            sort BOM::Market::UnderlyingDB->instance->get_symbols_for(
                market => [qw(forex )],
            )];
    },
);

has 'barrier1_delta' => (
    is         => 'rw',
    isa        => 'ArrayRef[Num]',
    lazy_build => 1,
);

has 'barrier2_delta' => (
    is         => 'rw',
    isa        => 'ArrayRef[Num]',
    lazy_build => 1,
);

has 'barrier_delta_list' => (
    is      => 'rw',
    isa     => 'ArrayRef[Num]',
    default => sub {
        [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95];
    },
);

has 'cut_off_time' => (
    is         => 'rw',
    isa        => 'ArrayRef[Str]',
    lazy_build => 1,
);

has 'cut_off_time_list' => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub {
        [
            '01:00', '02:00', '03:00', '04:00', '05:00', '06:00', '07:00', '08:00', '09:00', '10:00', '11:00', '12:00',
            '13:00', '14:00', '15:00', '16:00', '17:00', '18:00', '19:00', '20:00', '21:00', '22:00', '23:00', '23:59'
        ];
    },
);

has 'price_type' => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

has 'price_type_list' => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { ['none', 'theo', 'ask', 'bid'] },
);

has 'config' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_config {
    my $self       = shift;
    my $config_loc = "/home/git/regentmarkets/bom/t/BOM/Product/Benchmark/config.yml";
    die unless $config_loc;
    my $config = LoadFile($config_loc);
    return $config;
}

sub get_volsurface {
    my ($self, $underlying_symbol) = @_;

    my $data          = $self->config->{volsurface}->{$underlying_symbol};
    my $surface_data  = $data->{surface_data};
    my $recorded_date = $data->{recorded_date};
    my $cutoff        = $data->{cutoff};
    my $surface       = BOM::MarketData::VolSurface::Delta->new(
        underlying      => BOM::Market::Underlying->new($underlying_symbol),
        recorded_date   => Date::Utility->new($recorded_date),
        surface         => $surface_data,
        print_precision => undef,
        cutoff          => $cutoff,
        deltas          => [25, 50, 75],
    );

    return $surface;
}

has _vol_surface_validator => (
    is       => 'ro',
    isa      => 'BOM::MarketData::VolSurface::Validator',
    init_arg => undef,
    lazy     => 1,
    default  => sub { BOM::MarketData::VolSurface::Validator->new },
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

sub _build_bet_type {
    my $self = shift;
    return [$self->_get_value('bet_type', [])]->[0];
}

sub _build_barrier2_delta {
    my $self = shift;
    return [$self->_get_value('barrier2_delta', [])]->[0];
}

sub _build_barrier1_delta {
    my $self = shift;
    return [$self->_get_value('barrier1_delta', [])]->[0];
}

sub _build_cut_off_time {
    my $self = shift;
    return [$self->_get_value('cut_off_time', [])]->[0];
}

sub _build_maturity_days {
    my $self = shift;
    return [$self->_get_value('maturity_days', [])]->[0];
}

sub _build_output_format {
    my $self = shift;
    return $self->_get_value('output_format', '');
}

sub _build_payout_currency {
    my $self = shift;
    return [$self->_get_value('payout_currency', [])]->[0];
}

sub _build_offset {
    my $self = shift;
    return $self->_get_value('offset', 0);
}

sub _build_portfolio {
    my $self = shift;
    return 'BOM ' . $self->price_type . '-' . $self->output_format . '-' . Date::Utility->new()->datetime_ddmmmyy_hhmmss_TZ;
}

sub _build_price_type {
    my $self = shift;
    return $self->_get_value('price_type', '');
}

sub _build_underlying_symbol {
    my $self = shift;
    return [$self->_get_value('underlying_symbol', [])]->[0];
}

sub _is_two_barrier_bet {
    my $bet_type = shift;
    if ($bet_type eq 'RANGE' or $bet_type eq 'UPORDOWN') {
        return 1;
    }
    return;
}

sub _get_payout_currency_code {
    my $self              = shift;
    my $underlying_symbol = shift;
    my $payout_currnecy   = shift;

    if ($underlying_symbol =~ 'frx([A-Z]{3})([A-Z]{3})') {
        if ($payout_currnecy eq 'Base') {
            return $1;
        }
        if ($payout_currnecy eq 'Numeraire') {
            return $2;
        }
    }
    return '';
}

#Define a procedure to skip some unwanted optioned
sub _skip_the_option {
    my $bet_type       = shift;
    my $barrier1_delta = shift;
    my $barrier2_delta = shift;
    if ($bet_type eq 'RANGE' or $bet_type eq 'UPORDOWN') {
        if ($barrier1_delta >= 0.5 or $barrier2_delta <= 0.5) {
            return 1;
        }
    }
    return;
}

# this sub with produce the csv file compatible to upload to define the options
# Only generating the options with no price.
sub option_list {
    my $self = shift;
    my @contract;
    my $count          = 1;
    my $contract_class = 'BOM::Product::Benchmark::ContractGenerator::Bloomberg';
    my $max_rows       = $contract_class->max_number_of_uploadable_rows();
    my $content        = $contract_class->get_csv_header_no_price() . "\n";
    open(my $fh, ">", "/tmp/output.txt")    ## no critic
        or die "cannot open > output.txt: $!";

    foreach my $bet_type (@{$self->bet_type}) {

        foreach my $maturity_days (@{$self->maturity_days}) {
            foreach my $payout_currency (@{$self->payout_currency}) {
                foreach my $underlying_symbol (@{$self->underlying_symbol}) {
                    foreach my $cut_off_time (@{$self->cut_off_time}) {
                        foreach my $barrier1_delta (@{$self->barrier1_delta}) {
                            my @barrier2_delta = @{$self->barrier2_delta};
                            if (not _is_two_barrier_bet($bet_type)) {
                                @barrier2_delta = (0.95);
                            }
                            foreach my $barrier2_delta (@barrier2_delta) {

                                # Ignore the barrier2_delta if it is lower or equal to barrier1_delta
                                if ($barrier2_delta <= $barrier1_delta) {
                                    next;
                                }

                                # Some services accepts only x contracts per each upload.
                                if ($count > $max_rows
                                    or _skip_the_option($bet_type, $barrier1_delta, $barrier2_delta))
                                {
                                    next;
                                }
                                my $contract;
                                try {
                                    $contract = $contract_class->new({
                                        id                => $count,
                                        bet_type          => $bet_type,
                                        maturity_days     => $maturity_days,
                                        date_start        => Date::Utility->new(),
                                        payout_currency   => $self->_get_payout_currency_code($underlying_symbol, $payout_currency),
                                        underlying_symbol => $underlying_symbol,
                                        barrier1_delta    => $barrier1_delta,
                                        barrier2_delta    => $barrier2_delta,
                                        cut_off_time      => $cut_off_time,
                                        price_type        => $self->price_type,
                                        portfolio         => $self->portfolio . ' ' . (int($count / 1000) + 1),
                                        payout_amount     => $self->payout_amount,
                                    });

                                    my $line = $contract->get_csv_line_no_price;
                                    $count++;
                                    print $fh $line;
                                    $content .= $line . "\n";
                                }
                                catch {
                                    get_logger->error(
                                        "not able to process [$bet_type] [$maturity_days] [$underlying_symbol] [$payout_currency] [$barrier1_delta] [$barrier2_delta] [$cut_off_time] [$@]"
                                    );
                                };
                            }
                        }
                    }
                }
            }
        }
    }
    close $fh;
    if ($count > $max_rows) {

#$content = "#Only the first $max_rows records of $count records are included in this portfolio.\n" . $content;
    }
    return $content;
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

    my $headers      = BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_field_headers(\@lines);
    my $pricing_date = BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_pricing_date(\@lines);

    my $cleaned_lines  = BOM::Product::Benchmark::ContractGenerator::Bloomberg::clean_the_content(\@lines);
    my $contract_class = 'BOM::Product::Benchmark::ContractGenerator::Bloomberg';
    my $csv_header     = $contract_class->get_csv_header() . "\n";

    my $content;
    for (my $i = 1; $i < scalar @{$cleaned_lines}; $i++) {
        my $contract;
        my $line = $cleaned_lines->[$i];
        my $csv = Text::CSV->new({binary => 1});
        if (not $csv->parse($line)) {
            die('Unable to parse line ' . $line);
        }
        chomp($line);
        my @fields          = $csv->fields();
        my $expiry_date_bom = BOM::Product::Benchmark::ContractGenerator::Bloomberg::export_date_expiry(\@fields, $headers);
        my $r_rate          = BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_r_rate(\@fields, $headers);
        my $q_rate          = BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_q_rate(\@fields, $headers);

        if ($mini eq 'mini') {
            next
                if not BOM::Product::Benchmark::ContractGenerator::Bloomberg::get_mini(\@fields, $headers);
        }

        if ($expiry_date_bom->epoch <= $pricing_date->epoch) {
            next;
        }

        my $underlying_symbol = BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_underlying_symbol(\@fields, $headers);
        my $contract_args = {
            id                           => BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_external_id(\@fields,         $headers),
            bet_type                     => BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_bet_type(\@fields,            $headers),
            payout_currency              => BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_payout_currency(\@fields,     $headers),
            underlying_symbol            => $underlying_symbol,
            barrier1                     => BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_barrier1(\@fields,            $headers),
            cut_off_time                 => BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_cut_off_time(\@fields,        $headers),
            price_type                   => 'theo',
            portfolio                    => 'Reprice',
            spot                         => BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_spot(\@fields,                $headers),
            date_start                   => $pricing_date,
            expiry_date_bom              => $expiry_date_bom,
            date_pricing                 => $pricing_date,
            barrier2                     => BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_barrier2(\@fields,            $headers),
            bloomberg_exported_price_mid => BOM::Product::Benchmark::ContractGenerator::Bloomberg::exported_bloomberg_price_mid(\@fields, $headers),
            r                            => $r_rate / 100,
            q                            => $q_rate / 100,
            payout_amount                => $self->payout_amount,
        };

        my $fixture = BOM::Test::Data::Utility::SetupDatasetTestFixture->new;
        $fixture->setup_test_fixture({
                underlying => BOM::Market::Underlying->new($underlying_symbol),
                spot       => $contract_args->{spot}});
        $contract_args->{volsurface} = $self->get_volsurface($underlying_symbol);
        try {
            $contract = $contract_class->new($contract_args);
            $content .= $contract->get_csv_line(\@fields, $headers) . "\n";
        }
        catch {
            # running as script from console
            if ($line_ref) {
                print "not able to process line[$line] $@";
            } else {
                get_logger->warn("not able to process line[$line] $@");
            }
        };
    }
    return ($csv_header, $content);
}

__PACKAGE__->meta->make_immutable;
1;
