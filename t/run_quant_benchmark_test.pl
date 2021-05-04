#!/usr/bin/perl
package DatasetRunner;

use Moose;
with 'App::Base::Script';

use TAP::Harness;
use YAML::XS qw(LoadFile);
use Test::More qw(no_plan);
use Test::MockModule;
use File::Spec;

use lib qw(/home/git/regentmarkets/bom/t/BOM/Product);
use BOM::Test::Data::Utility::UnitTestRedis;

use Runner::Merlin;
use Runner::Superderivatives_EQ;
use Runner::Superderivatives_FX;
use Runner::Bloomberg;
use BOM::Config::Runtime;
use Date::Utility;
use Format::Util::Numbers qw(roundnear);
use Text::CSV;

sub documentation {
    return 'This script runs quant\'s pricing-related datasets';
}

sub _benchmark_testing_setup {

    $Quant::Framework::Underlying::interest_rates_source = 'market';

    my $file_path = '/home/git/regentmarkets/bom-quant-benchmark/t/csv/interest_rates.csv';
    my $csv       = Text::CSV->new({sep_char => ','});

    open(my $data, '<', $file_path) or die "Could not open '$file_path' $!\n";
    my $dummy_line       = <$data>;
    my $chronicle_writer = BOM::Config::Chronicle::get_chronicle_writer();
    while (my $line = <$data>) {
        chomp $line;

        if ($csv->parse($line)) {
            my @fields = $csv->fields();

            my $symbol = $fields[0];
            my %rates;

            for (my $i = 1; $i < scalar @fields; $i += 2) {
                my $tenor = $fields[$i];
                my $rate  = $fields[$i + 1];

                $rates{$tenor} = $rate;
            }

            $chronicle_writer->set(
                'interest_rates',
                $symbol,
                {
                    symbol => $symbol,
                    type   => 'market',
                    rates  => \%rates,
                    date   => '2010-01-01T00:00:00Z'
                },
                Date::Utility->new(),
            );
        } else {
            warn "Line could not be parsed: $line\n";
        }
    }

    close $data;

    $chronicle_writer->set('partial_trading', 'late_opens', {}, Date::Utility->new("2010-01-01"));

    return 1;
}

sub options {
    return [{
            name          => 'suite',
            documentation => 'which suite to run',
            option_type   => 'string',
            default       => 'mini',
        },
        {
            name          => 'which',
            documentation => 'which dataset that you wish to run',
            option_type   => 'string',
            default       => 'all',
        },
        {
            name          => 'file',
            documentation => 'csv file to parse. Only required for sdeq',
            option_type   => 'string',
            default       => '',
        },
    ];
}

has test_suite_mapper => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            merlin => 'Runner::Merlin',
            sdfx   => 'Runner::Superderivatives_FX',
            sdeq   => 'Runner::Superderivatives_EQ',
            ovra   => 'Runner::Bloomberg',
        };
    },
);

has 'test_suite' => (
    is         => 'rw',
    isa        => 'ArrayRef',
    lazy_build => 1,
);

sub _build_test_suite {
    my $self = shift;

    my $which = $self->getOption('which');
    my @what_to_run = ($which eq 'all') ? ('merlin', 'sdfx', 'sdeq', 'ovra',) : split ',', $which;

    return \@what_to_run;
}

sub script_run {
    my $self = shift;

    ok _benchmark_testing_setup, 'setup benchmark testing environment';

    use Data::Dumper;
    print Dumper $self->test_suite;

    eval {
        foreach my $test (@{$self->test_suite}) {
            my $test_class = $self->test_suite_mapper->{$test};
            my $report     = $test_class->new(suite => $self->getOption('suite'))->run_dataset($self->getOption('file'));
            $self->analyse_report($report, $test);
        }
    };
    if ($@) {
        print "[$@]";
        die $@;
    }

    done_testing;
}

sub analyse_report {
    my ($self, $report, $test) = @_;

    my $benchmark      = LoadFile('/home/git/regentmarkets/bom-quant-benchmark/t/benchmark.yml');
    my $test_benchmark = $benchmark->{$self->getOption('suite')}->{$test};
    foreach my $base_or_num (keys %$report) {
        foreach my $bet_type (keys %{$report->{$base_or_num}}) {
            subtest "$test benchmark" => sub {
                cmp_ok(
                    roundnear(0.0001, $report->{$base_or_num}->{$bet_type}->{avg}),
                    '<=',
                    roundnear(0.0001, $test_benchmark->{$base_or_num}->{$bet_type}->{avg}),
                    "Avg mid diff of bet_type[$bet_type] for [$base_or_num] is within benchmark"
                );
                cmp_ok(
                    roundnear(0.0001, $report->{$base_or_num}->{$bet_type}->{max}),
                    '<=',
                    roundnear(0.0001, $test_benchmark->{$base_or_num}->{$bet_type}->{max}),
                    "Max mid diff of bet_type[$bet_type] for [$base_or_num] is within benchmark"
                );
            };
        }
    }
}
no Moose;
__PACKAGE__->meta->make_immutable;

package main;
exit DatasetRunner->new()->run();
