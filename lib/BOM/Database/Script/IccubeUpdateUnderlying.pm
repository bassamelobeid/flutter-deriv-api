package BOM::Database::Script::IccubeUpdateUnderlying;
use strict;
use warnings;

use YAML::XS qw(LoadFile);
use Finance::Asset;
use BOM::Database::ClientDB;
use File::ShareDir;

sub run {
    my $u_file = Finance::Asset->instance->all_parameters;
    my $u_subm = LoadFile(File::ShareDir::dist_file('Finance-Asset',      'submarkets.yml'));
    my $u_mt   = LoadFile(File::ShareDir::dist_file('Finance-Underlying', 'underlyings.yml'));

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

        print "starting update underlying\n";

        foreach my $symbol (keys %{$u_file}) {
            my $symbol_file = $u_file->{$symbol};
            next if ref($symbol_file) ne 'HASH';

            $symbol_file->{market} //= $u_subm->{$symbol_file->{submarket}}->{market};
            $symbol_file->{market_type} = $u_mt->{$symbol}->{market_type} // 'financial';

            if (defined $u_db->{$symbol}) {
                my $symbol_db = $u_db->{$symbol};

                # check for changes & update row
                if (grep { ($symbol_file->{$_} //= '') ne ($symbol_db->{$_} //= '') } qw(market submarket quoted_currency market_type)) {
                    $update_sth->execute(
                        $symbol_file->{market},
                        $symbol_file->{submarket},
                        $symbol_file->{quoted_currency},
                        $symbol_file->{market_type}, $symbol
                    );
                    $upd++;
                }
            } else {
                # insert new underlying
                $insert_sth->execute(
                    $symbol,
                    $symbol_file->{market},
                    $symbol_file->{submarket},
                    $symbol_file->{quoted_currency},
                    $symbol_file->{market_type});
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
    return;
}

1;
