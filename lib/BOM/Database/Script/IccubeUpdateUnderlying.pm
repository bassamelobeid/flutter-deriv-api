package BOM::Database::Script::IccubeUpdateUnderlying;
use strict;
use warnings;

use YAML::XS qw(LoadFile);

use BOM::Database::ClientDB;
use File::ShareDir;
use Finance::Underlying;

sub run {

    my @underlyings = Finance::Underlying->all_underlyings();

    my $dbic = BOM::Database::ClientDB->new({
            broker_code => 'FOG',
            operation   => 'collector',
        }
        )->db->dbic
        or die "[$0] cannot create connection";

    my $txn = sub {

        my $u_db = $_->selectall_hashref(
            qq{
        SELECT * FROM data_collection.underlying_symbol_currency_mapper
    }, 'symbol'
        );

        my $insert_sth = $_->prepare(
            q{
        INSERT INTO data_collection.underlying_symbol_currency_mapper (symbol, market, submarket, quoted_currency, market_type) VALUES (?,?,?,?,?)
    }
        );

        my $update_sth = $_->prepare(
            q{
        UPDATE data_collection.underlying_symbol_currency_mapper SET
            market = ?,
            submarket = ?,
            quoted_currency = ?,
            market_type = ?
        WHERE symbol = ?
    }
        );

        my $ins = 0;
        my $upd = 0;

        print "starting to update underlying\n";

        foreach my $symbol_file (@underlyings) {
            my $symbol = $symbol_file->symbol;

            if (defined $u_db->{$symbol}) {
                my $symbol_db = $u_db->{$symbol};

                # check for changes & update row
                if (grep { $symbol_file->$_ ne ($symbol_db->{$_} //= '') } qw(market submarket quoted_currency market_type)) {
                    $update_sth->execute($symbol_file->market, $symbol_file->submarket, $symbol_file->quoted_currency,
                        $symbol_file->market_type, $symbol);
                    $upd++;
                }
            } else {
                # insert new underlying
                $insert_sth->execute($symbol, $symbol_file->market, $symbol_file->submarket, $symbol_file->quoted_currency,
                    $symbol_file->market_type);
                $ins++;
            }
        }
        return ($ins, $upd);
    };

    my ($ins, $upd) = $dbic->txn($txn);
    print "inserted $ins underlyings\n";
    if ($upd) {
        print "updated $upd underlyings -- you probably want to fully reload the cube.\n";
    }
    return 1;
}

1;
