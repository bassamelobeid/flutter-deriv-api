#!/usr/bin/perl
package DatasetRunner;

use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

use File::Slurp;
use TAP::Harness;
use YAML::XS qw(LoadFile);
use Test::More qw(no_plan);
use Test::MockModule;
use JSON qw(decode_json);
use File::Spec;

use lib qw(/home/git/regentmarkets/bom/t/BOM/Product);
use BOM::Test::Data::Utility::UnitTestRedis;

use Runner::Merlin;
use Runner::Superderivatives_EQ;
use Runner::Superderivatives_FX;
use Runner::Bloomberg;
use BOM::Platform::Runtime;
use Date::Utility;
use Format::Util::Numbers qw(roundnear);

sub documentation {
    return 'This script runs quant\'s pricing-related datasets';
}

sub _benchmark_testing_setup {
    BOM::Platform::Runtime->instance->app_config->quants->features->enable_parameterized_surface(0);
    BOM::Platform::Runtime->instance->app_config->quants->market_data->economic_announcements_source('forexfactory');

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
    ];
}

has test_suite_mapper => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        {
            merlin              => 'Runner::Merlin',
            sdfx                => 'Runner::Superderivatives_FX',
            sdeq                => 'Runner::Superderivatives_EQ',
            ovra                => 'Runner::Bloomberg',
            intraday_historical => 'Runner::IntradayFX',
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
    my @what_to_run = ($which eq 'all') ? ('merlin', 'sdfx', 'sdeq', 'ovra', 'intraday_historical',) : split ',', $which;

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
            my $report = $test_class->new(suite => $self->getOption('suite'))->run_dataset;
            $self->analyse_report($report, $test);
        }
    };
    if ($@) {
        print "[$@]";
    }

}

sub analyse_report {
    my ($self, $report, $test) = @_;

    my $benchmark = LoadFile('/home/git/regentmarkets/bom-quant-benchmark/t/benchmark.yml');
    if ($test eq 'intraday_historical') {
        my $test_benchmark = $benchmark->{intraday};
        foreach my $bet_type (keys %$report) {
            my $abs_expected = abs($test_benchmark->{$bet_type});
            my $abs_got      = abs($report->{$bet_type});
            my $abs_diff     = abs($abs_got - $abs_expected) / $abs_expected;
            cmp_ok($abs_diff, "<=", 0.1,  'intraday benchmark test for bet_type[' . $bet_type . ']');
            cmp_ok($abs_diff, ">=", 0.01, 'intraday benchmark test for bet_type[' . $bet_type . ']');
        }
    } else {
        my $test_benchmark = $benchmark->{$self->getOption('suite')}->{$test};
        foreach my $base_or_num (keys %$report) {
            foreach my $bet_type (keys %{$report->{$base_or_num}}) {
                subtest "$test benchmark" => sub {
                    cmp_ok(
                        roundnear(0.0001,$report->{$base_or_num}->{$bet_type}->{avg}),
                        '<=',
                        roundnear(0.0001,$test_benchmark->{$base_or_num}->{$bet_type}->{avg}),
                        "Avg mid diff of bet_type[$bet_type] base_or_num[$base_or_num] is within benchmark"
                    );
                    cmp_ok(
                        roundnear(0.0001,$report->{$base_or_num}->{$bet_type}->{max}),
                        '<=',
                        roundnear(0.0001,$test_benchmark->{$base_or_num}->{$bet_type}->{max}),
                        "Max mid diff of bet_type[$bet_type] base_or_num[$base_or_num] is within benchmark"
                    );
                };
            }
        }
    }
}
no Moose;
__PACKAGE__->meta->make_immutable;
done_testing;
package main;
exit DatasetRunner->new()->run();
