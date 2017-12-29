package BOM::Pricing::QueuePopulator::Japan;
use strict;
use warnings;

=head1 NAME

BOM::Pricing::QueuePopulator::Japan - adds Japan pricing entries to each pricing cycle

=head1 DESCRIPTION

This module is used by C<bin/populate_jp_price_queue.pl> to insert pricing requests for
all Japan contracts each pricing cycle.

For regulatory reasons, we need to price all contracts even when users are not actively
requesting them.

=cut

use BOM::Platform::Runtime;

use BOM::Product::ContractFinder;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use Encode;
use JSON::MaybeXS;
use List::UtilsBy qw(rev_nsort_by bundle_by);
use Pricing::Engine::EuropeanDigitalSlope;
use LandingCompany::Registry;
use Date::Utility;
use POSIX qw(floor);
use Time::HiRes qw(clock_nanosleep CLOCK_REALTIME TIMER_ABSTIME);

# Seconds between updates. This should match the figure used in the price_queue.pl script.
use constant PRICING_INTERVAL => 2;

# Number of keys to set per Redis call, used to reduce network latency overhead
use constant JOBS_PER_BATCH => 30;
# Reload appconfig regularly, in case any underlyings have been disabled -
# values are in seconds
use constant APP_CONFIG_REFRESH_INTERVAL => 60;

# This controls how many barriers each queue item represents. A higher number is more efficient,
# but time spent per queue item needs to be less than the pricing interval.
use constant BARRIERS_PER_BATCH => 2;

use Log::Any qw($log);

=head2 new

Instantiates - currently, no parameters are expected.

=cut

sub new {
    my ($class, %args) = @_;
    $args{appconfig_age} = 0;
    $args{redis}         = BOM::Platform::RedisReplicated::redis_pricer();
    return bless \%args, $class;
}

=head2 redis

Returns a Redis instance with access to write to the pricing queue.

=cut

sub redis { return shift->{redis} }

# Mapping from the contracts available to the contract types that we want to queue.
my %type_map = (
    PUT        => [qw(CALLE PUT)],
    ONETOUCH   => [qw(ONETOUCH NOTOUCH)],
    EXPIRYMISS => [qw(EXPIRYMISS EXPIRYRANGEE)],
    RANGE      => [qw(RANGE UPORDOWN)],
);

=head2 check_appconfig

Reloads appconfig if it has changed recently.

=cut

sub check_appconfig {
    my ($self) = @_;
    my $start = Time::HiRes::time;
    if ($start - $self->{appconfig_age} >= APP_CONFIG_REFRESH_INTERVAL) {
        BOM::Platform::Runtime->instance->app_config->check_for_update;
        $self->{appconfig_age} = $start;
    }
    return;
}

=head2 process

Process a single pricing interval.

=cut

# The 'no critic' line is to work around perlcritic complaints for
# the bundle_by { [ @_ ] } construct. Assigning @_ to a separate
# array is possible, but it complicates the already-length for() loop
# expression.
sub process {    ## no critic qw(Subroutines::RequireArgUnpacking)
    my ($self) = @_;

    my $start = Time::HiRes::time;
    $self->check_appconfig;
    my $landing_company = 'japan';
    # Get a full list of symbols since some may have been updated/disabled
    # since the last time
    my @symbols =
        LandingCompany::Registry::get($landing_company)->multi_barrier_offerings(BOM::Platform::Runtime->instance->get_offerings_config)
        ->values_for_key('underlying_symbol');
    my $now = Time::HiRes::time;
    $log->debugf("Retrieved symbols - %.2fms", 1000 * ($now - $start));

    my $finder = BOM::Product::ContractFinder->new;
    my @jobs;
    my $skipped = 0;
    for my $symbol (@symbols) {
        my $symbol_start  = Time::HiRes::time;
        my $contracts_for = $finder->multi_barrier_contracts_for({
            symbol          => $symbol,
            landing_company => $landing_company,
            country_code    => 'jp'
        });
        $now = Time::HiRes::time;
        $log->debugf("Retrieved contracts for %s - %.2fms", $symbol, 1000 * ($now - $symbol_start));

        PARAMETER:
        for my $contract_parameters (@{$contracts_for->{available}}) {
            unless (ref $contract_parameters->{contract_type}) {
                die "unknown contract_type?" unless $contract_parameters->{contract_type};
                next PARAMETER unless exists $type_map{$contract_parameters->{contract_type}};
                $contract_parameters->{contract_type} = $type_map{$contract_parameters->{contract_type}};
            }

            # Expired entries - barriers which are no longer relevant can be skipped
            my %expired;
            $expired{ref($_) ? join(',', @$_) : $_} = 1 for @{$contract_parameters->{expired_barriers}};
            BARRIER:
            for my $barriers (bundle_by { [@_] } BARRIERS_PER_BATCH, @{$contract_parameters->{available_barriers}}) {
                my @barriers;
                for my $bar (@$barriers) {
                    my ($barrier_desc) = map { ; ref($_) ? join(',', @$_) : $_ } $bar;
                    if (exists $expired{$barrier_desc}) {
                        $skipped++;
                    } else {
                        push @barriers, $bar;
                    }
                }
                next BARRIER unless @barriers;

                # At this point, we have contract(s) that we want to queue for pricing.
                my @pricing_queue_args = (
                    amount   => 1000,
                    barriers => [
                        map {
                            ;
                            ref($_)
                                ? +{
                                barrier2 => $_->[0],
                                barrier  => $_->[1],
                                }
                                : $_
                        } @barriers
                    ],
                    basis                  => 'payout',
                    contract_type          => $contract_parameters->{contract_type},
                    currency               => 'JPY',
                    date_expiry            => $contract_parameters->{trading_period}{date_expiry}{epoch},
                    landing_company        => 'japan',
                    price_daemon_cmd       => 'price',
                    proposal_array         => 1,
                    skips_price_validation => 1,
                    symbol                 => $symbol,
                    trading_period_start   => $contract_parameters->{trading_period}{date_start}{epoch},
                );
                $log->tracef("Contract parameters will be %s", \@pricing_queue_args);
                push @jobs, "PRICER_KEYS::" . Encode::encode_utf8(JSON::MaybeXS->new->encode(\@pricing_queue_args));
            }
        }
    }
    # Using a timing metric here so we can get min/max/avg
    DataDog::DogStatsd::Helper::stats_timing("pricer_queue.japan.jobs.queued",  0 + @jobs);
    DataDog::DogStatsd::Helper::stats_timing("pricer_queue.japan.jobs.skipped", $skipped);
    $log->debugf("Total of %d jobs to process, %d skipped", 0 + @jobs, $skipped);

    {    # Attempt to group the Redis operations to reduce network overhead
        my $redis = $self->redis;
        while (my @batch = splice @jobs, 0, JOBS_PER_BATCH) {
            $redis->mset(map { ; $_ => "1" } @batch);
        }
    }

    DataDog::DogStatsd::Helper::stats_timing("pricer_queue.japan.jobs.gather_time", 1000 * ($now - $start));

    return;
}

=head2 wait_for_next_cycle

Sleep to start of next pricing cycle.

=cut

sub wait_for_next_cycle {
    my $now = Time::HiRes::time;
    my $target = 1e9 * PRICING_INTERVAL * (1 + floor($now / PRICING_INTERVAL));
    $log->debugf("Will sleep until %s (current time %s)", map { $_->iso8601 } Date::Utility->new($target / 1e9), Date::Utility->new($now));
    clock_nanosleep(CLOCK_REALTIME, $target, TIMER_ABSTIME);
    return;
}

sub run {
    my ($self) = @_;
    while (1) {
        $self->process;
        $self->wait_for_next_cycle;
    }
    return 1;
}

1;

