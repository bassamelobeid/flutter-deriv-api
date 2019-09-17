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
    my @uls = Finance::Underlying::all_underlyings();

    my %default_underlying_group;
    $default_underlying_group{$_->{symbol}} = $_->{market} for @uls;

    return %default_underlying_group;
}

sub get_default_contract_group_mappings {
    my $contract_types = Finance::Contract::Category::get_all_contract_types();

    my %default_contract_group;
    $default_contract_group{$_} = $contract_types->{$_}->{category} for (keys %$contract_types);

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

1;
