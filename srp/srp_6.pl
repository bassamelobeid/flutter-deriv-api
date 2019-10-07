use strict;
use warnings;

use BOM::Database::ClientDB;

my $clientdb = BOM::Database::ClientDB->new( { broker_code => 'MF' } )->db->dbic;

# Get the following from MF database: email address, balance
my @fr_residence_clients = @{
    $clientdb->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT cli.loginid, COALESCE(ta.balance, 0) AS balance
                FROM betonmarkets.client as cli
                left join transaction.account AS ta ON cli.loginid = ta.client_loginid
                 where cli.residence = 'fr'",
                { Slice => {} } );
        }
    )
};

$clientdb->txn(
    fixup => sub {
        foreach my $fr_client (@fr_residence_clients) {

            my $balance = $fr_client->{balance};
            
            # If there is balance, mark as unwelcome. Otherwise, disable
            my $status = $balance == 0 ? 'disabled' : 'unwelcome';
            
            # Insert status
            $clientdb->run(
                ping => sub {
                    my $sth = $_->prepare(
                        'INSERT INTO betonmarkets.client_status(client_loginid, status_code, staff_name, reason) VALUES (?,?,?,?) ON CONFLICT DO NOTHING'
                    );
                    $sth->execute($fr_client->{loginid}, $status, 'SYSTEM', 'No binary options for clients residing in france');
                }
            );
        }
    }
);