package BOM::CompanyLimits::Groups;
use strict;
use warnings;

use Finance::Underlying;
use Finance::Contract::Category;
use LandingCompany::Registry;
use BOM::CompanyLimits::Helpers qw(get_redis);
use BOM::Config::Runtime;

# All code related to setting groups, changing groups, syncing
# groups from the database should be placed here. Nothing related
# to the buy call should be placed here.

my $all_groups = ['underlying', 'contract'];

sub get_default_underlying_group_mappings {
    my @uls                          = Finance::Underlying::all_underlyings();
    my %supported_underlying_symbols = _get_active_offerings('underlying_symbol');

    die 'Unable to filter out unused underlyings. Check app config redis instance.' unless %supported_underlying_symbols;

    my %default_underlying_group;
    $default_underlying_group{$_->{symbol}} = $_->{market} for (sort grep { $supported_underlying_symbols{$_->{symbol}} } @uls);

    return %default_underlying_group;
}

sub get_default_contract_group_mappings {
    my $contract_types           = Finance::Contract::Category::get_all_contract_types();
    my %supported_contract_types = _get_active_offerings('contract_type');

    die 'Unable to filter out unused contracts. Check app config redis instance.' unless %supported_contract_types;

    my %default_contract_group;
    $default_contract_group{$_} = $contract_types->{$_}->{category} for (sort grep { $supported_contract_types{$_} } keys %$contract_types);

    return %default_contract_group;
}

my (%underlying_groups_cache, %contract_groups_cache, $cache_date);

sub get_limit_groups {
    my ($bet_data) = @_;

    # Limit groups are cached to the next minute interval
    my $current_minute = int(time / 60);

    return _get_limit_groups($bet_data)
        if %underlying_groups_cache and $cache_date == $current_minute;

    # Limit setting currently all points to same redis server
    my $redis = get_redis('svg', 'limit_setting');

    $redis->hgetall(
        'contractgroups',
        sub {
            %contract_groups_cache = @{$_[1]};
        });
    $redis->hgetall(
        'underlyinggroups',
        sub {
            %underlying_groups_cache = @{$_[1]};
        });
    $redis->mainloop;

    $cache_date = $current_minute;

    return _get_limit_groups($bet_data);
}

sub _get_limit_groups {
    my ($bet_data) = @_;

    return ($contract_groups_cache{$bet_data->{bet_type}}, $underlying_groups_cache{$bet_data->{underlying_symbol}});
}

sub _get_active_offerings {
    my ($key) = @_;

    my $lc        = LandingCompany::Registry::get('virtual');                                     # get everything in offerings list.
    my $o_config  = BOM::Config::Runtime->instance->get_offerings_config();
    my @offerings = ($lc->basic_offerings($o_config), $lc->multi_barrier_offerings($o_config));

    my %supported_offerings =
        map { $_ => 1 }
        map { $_->values_for_key($key) } @offerings;

    return %supported_offerings;
}

1;
