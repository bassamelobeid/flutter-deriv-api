package BOM::CompanyLimits::Groups;
use strict;
use warnings;

use Finance::Underlying;
use Finance::Contract::Category;
use LandingCompany::Registry;
use BOM::Database::UserDB;
use BOM::CompanyLimits::Helpers qw(get_redis);
use BOM::Config::Runtime;

# All code related to setting groups, changing groups, syncing
# groups from the database should be placed here. Nothing related
# to the buy call should be placed here.

my $all_groups = ['underlying', 'contract'];

sub sync_group_to_redis {
    my @groups = @_;
    @groups = @$all_groups unless @groups;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    foreach my $group_name (@groups) {
        my $sql;
        # This seemingly verbose code in retrieving the sql is to prevent
        # the possibility of sql injection (though unlikely now)
        if ($group_name eq 'underlying') {
            $sql = "SELECT * FROM limits.underlying_group_mapping;";
        } elsif ($group_name eq 'contract') {
            $sql = "SELECT * FROM limits.contract_group_mapping;";
        } else {
            die "Unsupported limit group $group_name";
        }

        my $query_result = $dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef) });

        my @group_pairs;
        push @group_pairs, @$_ foreach (@$query_result);

        die "no $group_name in database" unless @group_pairs;

        # It does not matter which landing_company is used; it will be mapped to
        # the same Redis instance
        my $redis = get_redis('svg', 'limit_setting');

        my $hash_name = "${group_name}groups";
        $redis->multi(sub { });
        $redis->del($hash_name, sub { });
        $redis->hmset($hash_name, @group_pairs, sub { });
        $redis->exec(sub { });
        $redis->mainloop;
    }

    return;
}

# Pass in group names as variadic parameters - used for unit tests.
# In production/QA provisioning we use psql to load the groups via
# extract-limit-groups-to-db.pl
sub load_group_yml_to_db {
    my @groups = @_;
    @groups = @$all_groups unless @groups;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    foreach my $group_name (@groups) {
        my $sql = get_insert_group_sql($group_name);

        $dbic->run(
            fixup => sub {
                $_->selectall_arrayref($sql);
            });
    }

    return;
}

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

# Works kinda like a factory
sub get_insert_group_sql {
    my ($group_name) = @_;

    my $sql_query;
    if ($group_name eq 'underlying') {
        $sql_query = _get_insert_underlying_group_sql();
    } elsif ($group_name eq 'contract') {
        $sql_query = _get_insert_contract_group_sql();
    } else {
        die "invalid group. Choose between 'underlying' and 'contract'";
    }

    return $sql_query;
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

sub _get_insert_underlying_group_sql {
    my $sql = <<'EOF';
CREATE TEMP TABLE tt(LIKE limits.underlying_group_mapping) ON COMMIT DROP;
INSERT INTO tt(underlying, underlying_group) VALUES
EOF

    my %underlying_groups = get_default_underlying_group_mappings();
    $sql .= "('$_','$underlying_groups{$_}'),\n" for (keys %underlying_groups);
    $sql =~ s/,\n$/;\n/;    # substitute last comma with ;

    $sql .= <<'EOF';
INSERT INTO limits.underlying_group
SELECT DISTINCT underlying_group FROM tt
    ON CONFLICT(underlying_group) DO NOTHING;

INSERT INTO limits.underlying_group_mapping AS m
SELECT underlying, underlying_group FROM tt
    ON CONFLICT(underlying) DO UPDATE
   SET underlying_group=EXCLUDED.underlying_group
 WHERE m.underlying_group IS DISTINCT FROM EXCLUDED.underlying_group
RETURNING *;
EOF

    return $sql;
}

sub _get_insert_contract_group_sql {
    my $sql = <<'EOF';
WITH tt(bet_type, contract_group) AS (
  VALUES
EOF

    my %contracts = get_default_contract_group_mappings();
    $sql .= "('$_','$contracts{$_}'),\n" for (keys %contracts);
    $sql =~ s/,\n$/\n/;    # substitute last comma with ;

    $sql .= <<'EOF';
),
contract_groups AS (
INSERT INTO limits.contract_group
SELECT DISTINCT contract_group FROM tt
    ON CONFLICT(contract_group) DO NOTHING
)
INSERT INTO limits.contract_group_mapping AS m
SELECT bet_type, contract_group FROM tt
    ON CONFLICT(bet_type) DO UPDATE
   SET contract_group=EXCLUDED.contract_group
 WHERE m.contract_group IS DISTINCT FROM EXCLUDED.contract_group
RETURNING *;
EOF

    return $sql;
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
