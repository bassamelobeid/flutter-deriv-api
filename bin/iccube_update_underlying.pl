#!/usr/bin/perl

use strict;
use warnings;

use YAML::XS qw(LoadFile);
use BOM::Database::ClientDB;

my $u_file = LoadFile('/home/git/regentmarkets/bom/config/files/underlyings.yml');
my $u_subm = LoadFile('/home/git/regentmarkets/bom/config/files/submarkets.yml');

my $dbh = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
        operation   => 'collector',
    })->db->dbh or die "[$0] cannot create connection";
$dbh->{AutoCommit} = 0;
$dbh->{RaiseError} = 1;


my $u_db = $dbh->selectall_hashref(
    qq{
        SELECT * FROM data_collection.underlying_symbol_currency_mapper
    }, 'symbol');

my $insert_sth = $dbh->prepare(q{
        INSERT INTO data_collection.underlying_symbol_currency_mapper (symbol, market, submarket, quoted_currency) VALUES (?,?,?,?)
    });

my $update_sth = $dbh->prepare(q{
        UPDATE data_collection.underlying_symbol_currency_mapper SET
            market = ?,
            submarket = ?,
            quoted_currency = ?
        WHERE symbol = ?
    });

print "starting update underlying\n";

my $ins = 0;
my $upd = 0;
foreach my $symbol (keys %{$u_file}) {
    my $symbol_file = $u_file->{$symbol};
    next if ref($symbol_file) ne 'HASH';

    $symbol_file->{market} //= $u_subm->{$symbol_file->{submarket}}->{market};

    if (defined $u_db->{$symbol}) {
        my $symbol_db = $u_db->{$symbol};

        # check for changes & update row
        if ( grep { $symbol_file->{$_} ne $symbol_db->{$_} } qw(market submarket quoted_currency) ) {
            $update_sth->execute($symbol_file->{market}, $symbol_file->{submarket}, $symbol_file->{quoted_currency}, $symbol);
            $upd++;
        }
    } else {
        # insert new underlying
        $insert_sth->execute($symbol, $symbol_file->{market}, $symbol_file->{submarket}, $symbol_file->{quoted_currency});
        $ins++;
    }
}

$dbh->commit;

print "inserted $ins underlyings\n";
if ($upd) {
    print "updated $upd underlyings -- you probably want to fully reload the cube.\n";
}

$dbh->disconnect;

