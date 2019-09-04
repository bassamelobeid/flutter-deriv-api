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

sub sync_underlying_groups {
    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    my $sql = q{
	SELECT underlying, underlying_group FROM limits.underlying_group_mapping;
    };
    my $bet_market = $dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef) });

    my @symbol_underlying;
    push @symbol_underlying, @$_ foreach (@$bet_market);

    # TODO: we are hard coding the landing company when setting limits
    get_redis('svg', 'limit_setting')->hmset('underlyinggroups', @symbol_underlying);

    return;
}

sub sync_contract_groups {
    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    my $sql = q{
	SELECT bet_type, contract_group FROM limits.contract_group_mapping;
    };
    my $bet_grp = $dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef) });

    my @contract_grp;
    push @contract_grp, @$_ foreach (@$bet_grp);

    # TODO: we are hard coding the landing company when setting limits
    get_redis('svg', 'limit_setting')->hmset('contractgroups', @contract_grp);

    return;
}

sub load_underlyings_yml_to_db {
    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    my $sql  = get_insert_underlying_group_sql();

    my $output = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref($sql);
        });

    return $output;
}

sub load_contracts_yml_to_db {
    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    my $sql  = get_insert_contract_group_sql();

    my $output = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref($sql);
        });

    return $output;
}

sub get_default_underlying_group_mappings {
    my @uls = Finance::Underlying::all_underlyings();

    my %supported_underlying_symbols = _get_active_offerings('underlying_symbol');
    my %default_underlying_group;

    if (%supported_underlying_symbols) {
        $default_underlying_group{$_->{symbol}} = $_->{market} for (sort grep { $supported_underlying_symbols{$_->{symbol}} } @uls);
    } else {
        # Supported underlying symbols cannot be empty; so do not filter if none exists
        warn 'Unable to filter out unused underlyings';
        $default_underlying_group{$_->{symbol}} = $_->{market} for (@uls);
    }

    return %default_underlying_group;
}

sub get_insert_underlying_group_sql {
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

sub get_insert_contract_group_sql {
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

sub get_default_contract_group_mappings {
    my $contract_types           = Finance::Contract::Category::get_all_contract_types();
    my %supported_contract_types = _get_active_offerings('contract_type');
    my %default_contract_group;

    if (%supported_contract_types) {
        $default_contract_group{$_} = $contract_types->{$_}->{category} for (sort grep { $supported_contract_types{$_} } keys %$contract_types);
    } else {
        # Supported contract groups cannot be empty; so do not filter if none exists
        warn 'Unable to filter out unused contracts';
        $default_contract_group{$_} = $contract_types->{$_}->{category} for (keys %$contract_types);
    }

    return %default_contract_group;
}

my $offerings_cache;

sub _get_active_offerings {
    my ($key) = @_;

    $offerings_cache //= do {
        my $lc        = LandingCompany::Registry::get('virtual');                                     # get everything in offerings list.
        my $o_config  = BOM::Config::Runtime->instance->get_offerings_config();
        my @offerings = ($lc->basic_offerings($o_config), $lc->multi_barrier_offerings($o_config));
        \@offerings;
    };

    my %supported_offerings =
        map { $_ => 1 }
        map { $_->values_for_key($key) } @$offerings_cache;

    return %supported_offerings;
}

1;
