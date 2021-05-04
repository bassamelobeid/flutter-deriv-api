package CSVParser::Merlin;

=head1 NAME

MerlinCSVParser

=head1 DESCRIPTION

Parses our Merlin CSV file, converting the raw data into
information in our various internal format.

=cut

use Moose;
use Text::CSV::Slurp;
use SetupDatasetTestFixture;
use Quant::Framework::VolSurface::Delta;
use BOM::MarketData qw(create_underlying);
use Text::CSV;
use YAML::XS qw(LoadFile);

=head1 ATTRIBUTES

=head2 merlin_csv

The location of the merlin CSV file.

=cut

has merlin_csv => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has suite => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

=head2 max_expiry

Throw away vol smiles for maturities above this max.
Defaults to -1.

=cut

has max_expiry => (
    is      => 'ro',
    isa     => 'Int',
    default => -1,
);

has _expiry => (
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    default => sub {
        {
            '15TK' => {
                local => 'Tokyo 15:00',
                bom   => '06:00:00',
            },
            '10NY' => {
                local => 'New York 10:00',
                bom   => '14:00:00',
            },
        };
    },
);

has _mapper => (
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
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

has pre_filters => (
    is       => 'ro',
    isa      => 'ArrayRef',
    required => 1,
);

has records_to_price => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
);

=head2 records

An ArrayRef of HashRefs, each corresponding to one line
from the CSV file, and containing all info necessary for
us to run our various tests.

=cut

has records => (
    is         => 'ro',
    isa        => 'ArrayRef',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build_records {
    my $self                  = shift;
    my $interest_rates_config = _get_interest_rate_data();
    my $csv                   = Text::CSV::Slurp->load(file => $self->merlin_csv);
    my %csv                   = map { $_->{bet_num} => $_ } @$csv;
    my @records_to_execute    = map { $csv{$_} } @{$self->pre_filters};
    @records_to_execute = grep { $_->{mini} } @records_to_execute if $self->suite eq 'mini';
    my @records;

    my $previous_underlying_symbol = '';
    my $previous_underlying;
    my $previous_surface;

    foreach my $line (@records_to_execute) {
        next if not $line->{Underlying};
        my $current_underlying_symbol = 'frx' . $line->{Underlying};

        my %record = (
            underlying_symbol => $current_underlying_symbol,
            date_start        => Date::Utility->new($line->{Epoch_time_now}),
            volcut            => $line->{VolCut},
            cut               => $line->{Cut},
            current_spot      => $line->{Spot},
            q_rate            => $line->{UNDDepo},
            r_rate            => $line->{ACCDepo},
            currency          => $line->{PayoutCurrency},
            payout            => $line->{Payout},
            numeraire         => substr($line->{Underlying}, 3, 6),
            bet_type          => $self->_mapper->{$line->{Type}},
            merlin_ask        => $line->{AskPrice_Live},
            merlin_bid        => abs($line->{BidPrice_Live}),
            merlin_tv         => $line->{TV},
            bet_num           => $line->{bet_num},
            atm_vol           => $line->{ATMVol},
            date_expiry       => _get_formatted_date_expiry($line->{Expiry}, $self->_expiry->{$line->{Cut}}->{bom}),
        );

        if ($line->{Strike}) {
            $record{barrier} = $line->{Strike};
        } elsif ($line->{UpperBarrier}) {
            if ($line->{LowerBarrier}) {
                $record{high_barrier} = $line->{UpperBarrier};
                $record{low_barrier}  = $line->{LowerBarrier};
            } else {
                $record{barrier} = $line->{UpperBarrier};
            }
        } else {
            $record{barrier} = 'S0P';
        }

        next if $record{date_expiry}->days_between($record{date_start}) > 365;

        $record{underlying} = create_underlying({
            symbol        => 'frx' . $line->{Underlying},
            closed_weight => 0.05,
        });

        my @smile_data   = map { $line->{$_ . ':T Days ATM 25RR 10RR 25BF 10BF'} } (1 .. 36);
        my $surface_data = $self->_set_surface_data([@smile_data]);
        my $surface_date = Date::Utility->new($record{date_start}->truncate_to_day->epoch + 14 * 3600);

        $record{surface} = Quant::Framework::VolSurface::Delta->new(
            underlying       => $record{underlying},
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
            creation_date    => $surface_date,
            surface          => $surface_data,
            print_precision  => undef,
            cutoff           => $self->_expiry->{$record{volcut}}->{local},
        );

        my $asset_symbol           = $record{underlying}->asset_symbol;
        my $quoted_currency_symbol = $record{underlying}->quoted_currency_symbol;

        my $rate = {
            asset_rate           => {continuous => $interest_rates_config->{$asset_symbol}},
            quoted_currency_rate => $interest_rates_config->{$quoted_currency_symbol},
        };

        my $fixture = SetupDatasetTestFixture->new();
        $fixture->setup_test_fixture({
                underlying => $record{underlying},
                rates      => $rate,
                date       => $record{date_start}});

        $record{transformed_cut} = 0;
        if ($record{cut} ne $record{volcut}) {
            $record{surface} = $record{surface}->clone({
                surface => $record{surface}->generate_surface_for_cutoff($self->_expiry->{$record{cut}}->{local}),
                cutoff  => $self->_expiry->{$record{cut}}->{local},
            });
            $record{transformed_cut} = 1;
        }
        push @records, \%record;

        ($previous_underlying, $previous_underlying_symbol, $previous_surface) = ($record{underlying}, $record{underlying}->symbol, $record{surface});
    }
    return \@records;
}

sub _get_formatted_date_expiry {
    my ($date, $time) = @_;

    my @expiry_bits = split /\//, $date;
    $date = join '-', ($expiry_bits[2], sprintf('%02d', $expiry_bits[0]), sprintf('%02d', $expiry_bits[1]));
    my $date_expiry = Date::Utility->new($date . ' ' . $time);
    return $date_expiry;
}

sub _set_surface_data {
    my ($self, $smile_data) = @_;

    my $surface_data;
    foreach my $data (@{$smile_data}) {
        my @vol_bits = split /\s+/, $data;

        next if scalar @vol_bits < 7;

        my $days = $vol_bits[1];
        next if ($self->max_expiry > 0 and $days > $self->max_expiry);

        $days = 'ON' if $days == 1;

        my $ATM   = $vol_bits[2] / 100;
        my $RR_10 = $vol_bits[4] / 100;
        my $RR_25 = $vol_bits[3] / 100;
        my $BF_10 = $vol_bits[6] / 100;
        my $BF_25 = $vol_bits[5] / 100;

        my $smile = {
            10 => ($ATM + .5 * $RR_10 + $BF_10),
            25 => ($ATM + .5 * $RR_25 + $BF_25),
            50 => $ATM,
            75 => ($ATM - .5 * $RR_25 + $BF_25),
            90 => ($ATM - .5 * $RR_10 + $BF_10),
        };

        $surface_data->{$days} = {
            smile      => $smile,
            vol_spread => {
                50 => 0.1,
            },
        };
    }

    return $surface_data;
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

no Moose;
__PACKAGE__->meta->make_immutable;
1;
