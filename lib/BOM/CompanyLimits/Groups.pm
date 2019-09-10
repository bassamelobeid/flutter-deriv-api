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
        my $sql = "SELECT * FROM limits.${group_name}_group_mapping;";
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

sub change_underlying_group_mapping {
# TODO: Changing underlying groups should be done within the Redis instance itself;
#       to sync with database would invite descrepancies with the data within Redis.
#       We could rebuild all underlying group values using underlying values, but a
#       more optimal way is to only update underlying groups that are affected by
#       the change.
#
#       We can break down the change of underlying group to individual operations
#       where one underlying u is moved from group g_from to g_to. Each operation
#       can execute as an independent transaction; we do not need to block operations
#       until all underlyings have been transferred.
#
#       To transfer an underlying, we take all values from key combinations with *,u,*
#       via HSCAN and decrement from g_from and increment g_to. To execute within a
#       single transaction, we need to use a lua script.
#
}

sub change_contract_group_mapping {
# TODO
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
CREATE TEMP TABLE tt(LIKE limits.contract_group_mapping) ON COMMIT DROP;
INSERT INTO tt(bet_type, contract_group) VALUES
EOF

    my %contracts = get_default_contract_group_mappings();
    $sql .= "('$_','$contracts{$_}'),\n" for (keys %contracts);
    $sql =~ s/,\n$/;\n/;    # substitute last comma with ;

    $sql .= <<'EOF';
INSERT INTO limits.contract_group
SELECT DISTINCT contract_group FROM tt
    ON CONFLICT(contract_group) DO NOTHING;

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
