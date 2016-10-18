package BOM::Platform::Offerings;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw( get_offerings_with_filter get_offerings_flyby get_permitted_expiries get_contract_specifics validate_offerings);

use Cache::RedisDB;
use FlyBy;
use List::MoreUtils qw( uniq all );
use Time::Duration::Concise;

use Finance::Asset;
use BOM::Platform::Runtime;
use BOM::Platform::LandingCompany::Registry;
use YAML::XS qw(LoadFile);

my $contract_type_config     = LoadFile('/home/git/regentmarkets/bom-platform/config/offerings/contract_types.yml');
my $contract_category_config = LoadFile('/home/git/regentmarkets/bom-platform/config/offerings/contract_categories.yml');
my %contract_offerings       = (
    japan  => LoadFile('/home/git/regentmarkets/bom-platform/config/offerings/japan.yml'),
    common => LoadFile('/home/git/regentmarkets/bom-platform/config/offerings/common.yml'),
);

my $cache_namespace = 'OFFERINGS';

# Keep these in sync with reality.
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
    min_historical_pricer_duration => 'historical_pricer_min',
    max_historical_pricer_duration => 'historical_pricer_max',
);

# Flush cached offerings on services restart.
# This makes sure that we recalculate offerings based on the new yaml files (product_offerings.yml & landing_company.yml).
_flush_offerings();

sub _make_new_flyby {
    my $landing_company_short = shift;

    my $runtime = BOM::Platform::Runtime->instance;
    my $fb      = FlyBy->new;
    # If trading is suspended on trading platform, returns an empty flyby object.
    return $fb if $runtime->app_config->system->suspend->trading;

    my $app_config_rev  = $runtime->app_config->current_revision;
    my $landing_company = BOM::Platform::LandingCompany::Registry::get($landing_company_short);
    my %suspended_underlyings =
        map { $_ => 1 } (
        @{$runtime->app_config->quants->underlyings->suspend_trades},
        @{$runtime->app_config->quants->underlyings->suspend_buy},
        @{$runtime->app_config->quants->underlyings->disabled_due_to_corporate_actions});
    my %suspended_markets        = map { $_ => 1 } @{$runtime->app_config->quants->markets->disabled};
    my %suspended_contract_types = map { $_ => 1 } @{$runtime->app_config->quants->features->suspend_claim_types};

    my %legal_allowed_contract_types = map { $_ => 1 } @{$landing_company->legal_allowed_contract_types};
    my %legal_allowed_markets        = map { $_ => 1 } @{$landing_company->legal_allowed_markets};
    my $offerings = $contract_offerings{$landing_company->legal_allowed_offerings};
    my $uc        = Finance::Asset->instance;

    foreach my $underlying_symbol (sort keys %$offerings) {
        next if exists $suspended_underlyings{$underlying_symbol};
        my $ul = $uc->get_parameters_for($underlying_symbol);
        next unless $legal_allowed_markets{$ul->{market}};
        next if $suspended_markets{$ul->{market}};
        my %record = (
            market            => $ul->{market},
            submarket         => $ul->{submarket},
            underlying_symbol => $ul->{symbol},
            exchange_name     => $ul->{exchange_name},
        );
        foreach my $cc_code (sort keys %{$offerings->{$underlying_symbol}}) {
            $record{contract_category} = $cc_code;
            my $category = $contract_category_config->{$cc_code};
            $record{contract_category_display} = $category->{display_name};
            foreach my $expiry_type (sort keys %{$offerings->{$underlying_symbol}{$cc_code}}) {
                $record{expiry_type} = $expiry_type;
                foreach my $start_type (sort keys %{$offerings->{$underlying_symbol}{$cc_code}{$expiry_type}}) {
                    $record{start_type} = $start_type;
                    foreach my $barrier_category (sort keys %{$offerings->{$underlying_symbol}{$cc_code}{$expiry_type}{$start_type}}) {
                        $record{barrier_category} = $barrier_category;
                        foreach my $contract_type (@{$category->{available_types}}) {
                            next unless $legal_allowed_contract_types{$contract_type};
                            next if $suspended_contract_types{$contract_type};
                            $record{sentiment}        = $contract_type_config->{$contract_type}{sentiment};
                            $record{contract_display} = $contract_type_config->{$contract_type}{display_name};
                            $record{contract_type}    = $contract_type;
                            my $permitted = _exists_value($offerings->{$underlying_symbol}, \%record);
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
    Cache::RedisDB->set($cache_namespace . '_' . $landing_company->short, $app_config_rev, $fb, 86399);

    return $fb;
}

{
    my %cache;

    sub get_offerings_flyby {
        my $landing_company = shift;

        $landing_company = 'costarica' unless $landing_company;

        my $app_config_rev = BOM::Platform::Runtime->instance->app_config->current_revision || 0;

        return $cache{$landing_company}->[1]
            if exists $cache{$landing_company}
            and $cache{$landing_company}->[0] == $app_config_rev;

        my $cached_fb = Cache::RedisDB->get($cache_namespace . '_' . $landing_company, $app_config_rev) // _make_new_flyby($landing_company);
        $cache{$landing_company} = [$app_config_rev, $cached_fb];

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

    die 'Must supply an output key' unless defined $what;
    my $landing_company = delete $args->{landing_company};
    my $fb              = get_offerings_flyby($landing_company);

    return (not keys %$args) ? $fb->values_for_key($what) : $fb->query($args, [$what]);
}

# This skips the FlyBy in favor of digging in directly when the way to find the info
# is completely specified.
# This is an optimization for pricing/purchase speed.
sub get_contract_specifics {
    my $args = shift;

    die 'Improper arguments to get_contract_specifics'
        unless (all { exists $args->{$_} } (qw(underlying_symbol contract_category barrier_category expiry_type start_type)));

    my $fb = get_offerings_flyby($args->{landing_company});

    my @query_result = $fb->query({
            underlying_symbol => $args->{underlying_symbol},
            contract_category => $args->{contract_category},
            expiry_type       => $args->{expiry_type},
            start_type        => $args->{start_type},
            barrier_category  => $args->{barrier_category},
        },
        [qw(min_contract_duration max_contract_duration min_historical_pricer_duration max_historical_pricer_duration)]);
    my ($min, $max, $historical_min, $historical_max) = @{$query_result[0] // []};

    my @data = (['permitted', $min, $max], ['historical', $historical_min, $historical_max]);

    my %specifics;
    if ($args->{expiry_type} eq 'tick') {
        %specifics = map { $_->[0] => {min => $_->[1], max => $_->[2]} }
            grep { $_->[1] and $_->[2] } @data;
    } else {
        %specifics =
            map { $_->[0] => {min => Time::Duration::Concise->new(interval => $_->[1]), max => Time::Duration::Concise->new(interval => $_->[2])} }
            grep { $_->[1] and $_->[2] } @data;
    }

    return \%specifics;
}

sub _exists_value {
    my ($hash_ref, $args) = @_;

    return {%$hash_ref}->{$args->{contract_category}}->{$args->{expiry_type}}->{$args->{start_type}}->{$args->{barrier_category}};
}

sub get_permitted_expiries {
    my $args = shift;

    return _do_min_max('min_contract_duration', 'max_contract_duration', $args);
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
