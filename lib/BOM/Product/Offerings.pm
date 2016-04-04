package BOM::Product::Offerings;

use strict;
use warnings;

use base qw( Exporter );
our @EXPORT_OK = qw( get_offerings_with_filter get_offerings_flyby get_permitted_expiries get_historical_pricer_durations get_contract_specifics );

use Cache::RedisDB;
use Carp qw( croak );
use FlyBy;
use List::MoreUtils qw( uniq all );
use Time::Duration::Concise;

use BOM::Market::Underlying;
use BOM::Platform::Runtime;
use BOM::Product::Contract::Category;
use BOM::Platform::Context;
use BOM::Platform::Runtime::LandingCompany::Registry;
use YAML::XS qw(LoadFile);

my $contract_type_config = LoadFile('/home/git/regentmarkets/bom/config/files/contract_types.yml');

my $cache_namespace = 'OFFERINGS';

# Keep these in sync with reality.
our $DEFAULT_MAX_PAYOUT = {
    USD => 100_000,
    EUR => 100_000,
    GBP => 100_000,
    AUD => 100_000,
    JPY => 10_000_000,
};
our $BARRIER_CATEGORIES = {
    callput      => ['euro_atm', 'euro_non_atm'],
    endsinout    => ['euro_non_atm'],
    touchnotouch => ['american'],
    staysinout   => ['american'],
    digits       => ['non_financial'],
    asian        => ['asian'],
    spreads      => ['spreads'],
};
my %record_map = (
    min_contract_duration          => 'min',
    max_contract_duration          => 'max',
    payout_limit                   => 'payout_limit',
    min_historical_pricer_duration => 'historical_pricer_min',
    max_historical_pricer_duration => 'historical_pricer_max',
);

# Flush cached offerings on services restart.
# This makes sure that we recalculate offerings based on the new yaml files (product_offerings.yml & landing_company.yml).
_flush_offerings();

sub _make_new_flyby {
    my $landing_company_short = shift;

    my $landing_company = BOM::Platform::Runtime::LandingCompany::Registry->new->get($landing_company_short);
    my %category_cache;    # Per-run to catch differences.
    my $runtime = BOM::Platform::Runtime->instance;
    my %suspended_underlyings =
        map { $_ => 1 } (@{$runtime->app_config->quants->underlyings->suspend_trades}, @{$runtime->app_config->quants->underlyings->suspend_buy});
    my $app_config_rev = $runtime->app_config->current_revision;

    my $fb                           = FlyBy->new;
    my %legal_allowed_contract_types = map { $_ => 1 } @{$landing_company->legal_allowed_contract_types};
    my %legal_allowed_markets        = map { $_ => 1 } @{$landing_company->legal_allowed_markets};
    my @legal_allowed_underlyings    = @{$landing_company->legal_allowed_underlyings};
    my @underlyings =
          $legal_allowed_underlyings[0] ne 'all'
        ? @legal_allowed_underlyings
        : (keys %{$BOM::Market::Underlying::PRODUCT_OFFERINGS});

    foreach my $underlying_symbol (@underlyings) {
        next if exists $suspended_underlyings{$underlying_symbol};
        my $ul = BOM::Market::Underlying->new($underlying_symbol);
        next unless $legal_allowed_markets{$ul->market->name};
        my %record = (
            market            => $ul->market->name,
            submarket         => $ul->submarket->name,
            underlying_symbol => $ul->symbol,
            exchange_name     => $ul->exchange_name,
        );
        foreach my $cc_code (keys %{$ul->contracts}) {
            $record{contract_category} = $cc_code;
            $category_cache{$cc_code} //= BOM::Product::Contract::Category->new($cc_code);
            $record{contract_category_display} = $category_cache{$cc_code}->{display_name};
            foreach my $expiry_type (sort keys %{$ul->contracts->{$cc_code}}) {
                $record{expiry_type} = $expiry_type;
                foreach my $start_type (sort keys %{$ul->contracts->{$cc_code}->{$expiry_type}}) {
                    $record{start_type} = $start_type;
                    foreach my $barrier_category (sort keys %{$ul->contracts->{$cc_code}->{$expiry_type}->{$start_type}}) {
                        $record{barrier_category} = $barrier_category;
                        foreach my $contract_type (@{$category_cache{$cc_code}->available_types}) {
                            next unless $legal_allowed_contract_types{$contract_type};
                            $record{sentiment}        = $contract_type_config->{$contract_type}{sentiment};
                            $record{contract_display} = $contract_type_config->{$contract_type}{display_name};
                            $record{contract_type}    = $contract_type;
                            my $permitted = _exists_value($ul->contracts, \%record);
                            while (my ($rec_key, $from_attr) = each %record_map) {
                                $record{$rec_key} = $permitted->{$from_attr};
                            }
                            $fb->add_records({%record});
                        }
                    }
                }
            }
        }
    }
    # Machine leveling caching for as long as it is valid.
    Cache::RedisDB->set($cache_namespace . '_' . BOM::Platform::Context::request()->language . '_' . $landing_company->short,
        $app_config_rev, $fb, 86399);

    return $fb;
}

{
    my %cache;

    sub get_offerings_flyby {
        my $landing_company = shift;

        $landing_company = 'costarica' unless $landing_company;

        my $app_config_rev = BOM::Platform::Runtime->instance->app_config->current_revision || 0;
        my $lang = BOM::Platform::Context::request()->language;

        return $cache{$lang}{$landing_company}->[1]
            if exists $cache{$lang}
            and exists $cache{$lang}{$landing_company}
            and $cache{$lang}{$landing_company}->[0] == $app_config_rev;

        my $cached_fb = Cache::RedisDB->get($cache_namespace . '_' . $lang . '_' . $landing_company, $app_config_rev)
            // _make_new_flyby($landing_company);
        $cache{$lang}{$landing_company} = [$app_config_rev, $cached_fb];

        return $cached_fb;
    }

    sub _flush_offerings {
        %cache = ();
        my $redis = Cache::RedisDB->redis;
        $redis->del($_) foreach (@{$redis->keys("$cache_namespace*")});
        return;
    }
}

sub get_offerings_with_filter {
    my ($what, $args) = @_;

    croak 'Must supply an output key' unless defined $what;
    my $landing_company = delete $args->{landing_company};
    my $fb              = get_offerings_flyby($landing_company);

    return (not keys %$args) ? $fb->values_for_key($what) : $fb->query($args, [$what]);
}

# This skips the FlyBy in favor of digging in directly when the way to find the info
# is completely specified.
# This is an optimization for pricing/purchase speed.
sub get_contract_specifics {
    my $args = shift;

    croak 'Improper arguments to get_contract_specifics'
        unless (all { exists $args->{$_} } (qw(underlying_symbol contract_category barrier_category expiry_type start_type)));

    my $to_format = ($args->{expiry_type} eq 'tick') ? sub { $_[0]; } : sub { Time::Duration::Concise->new(interval => $_[0]) };
    my $ul = BOM::Market::Underlying->new($args->{underlying_symbol});

    my $result = {payout_limit => $DEFAULT_MAX_PAYOUT};

    if (my $allowed = _exists_value($ul->contracts, $args)) {
        foreach my $side (grep { exists $allowed->{$_} } (qw(min max historical_pricer_min historical_pricer_max))) {
            my $shortened = $side;
            $shortened =~ s/^historical_pricer_//;
            $result->{($shortened eq $side) ? 'permitted' : 'historical'}{$shortened} = $to_format->($allowed->{$side});
        }
        $result->{payout_limit} = $allowed->{payout_limit} if (defined $allowed->{payout_limit});
    }

    return $result;
}

sub _exists_value {
    my ($hash_ref, $args) = @_;

    return {%$hash_ref}->{$args->{contract_category}}->{$args->{expiry_type}}->{$args->{start_type}}->{$args->{barrier_category}};
}

sub get_permitted_expiries {
    my $args = shift;

    return _do_min_max('min_contract_duration', 'max_contract_duration', $args);
}

sub get_historical_pricer_durations {
    my $args = shift;

    return _do_min_max('min_historical_pricer_duration', 'max_historical_pricer_duration', $args);
}

sub _do_min_max {

    my ($min_field, $max_field, $args) = @_;

    my $result = {};

    return $result unless scalar keys %$args;

    my $fb = get_offerings_flyby();

    my @possibles = $fb->query($args, ['expiry_type', $min_field, $max_field]);
    foreach my $actual_et (uniq map { $_->[0] } @possibles) {
        my @remaining = grep { $_->[0] eq $actual_et && $_->[1] && $_->[2] } @possibles;
        my @mins =
            ($actual_et eq 'tick')
            ? sort { $a <=> $b } map { $_->[1] } @remaining
            : sort { $a->seconds <=> $b->seconds } map { Time::Duration::Concise->new(interval => $_->[1]) } @remaining;
        my @maxs =
            ($actual_et eq 'tick')
            ? sort { $b <=> $a } map { $_->[2] } @remaining
            : sort { $b->seconds <=> $a->seconds } map { Time::Duration::Concise->new(interval => $_->[2]) } @remaining;
        $result->{$actual_et} = {
            min => $mins[0],
            max => $maxs[0],
        } if (defined $mins[0] and defined $maxs[0]);
    }

    # If they explicitly ask for a single expiry_type give just that one.
    if ($args->{expiry_type} and my $trimmed = $result->{$args->{expiry_type}}) {
        $result = $trimmed;
    }

    return $result;
}

1;
