package BOM::CompanyLimits::Groups;
use strict;
use warnings;

use BOM::Database::UserDB;
use BOM::CompanyLimits::Helpers qw(get_redis);

# All code related to setting groups, changing groups, syncing
# groups from the database should be placed here. Nothing related
# to the buy call should be placed here.

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
1;
