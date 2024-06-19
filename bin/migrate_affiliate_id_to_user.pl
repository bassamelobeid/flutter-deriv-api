use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::User;
use BOM::User::Client;

=head2 migrate_affiliate_id_to_user.pl

Copies affiliate_id from betonmarkets.payment_agent table to user.affiliate table.

=cut

my $client_dbic = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    })->db->dbic;

my $row_count     = 0;
my $updated_count = 0;

$client_dbic->run(
    fixup => sub {
        my $sth = $_->prepare(
            " 
        SELECT pa.affiliate_id as affiliate_id,
              pa.client_loginid as loginid
          FROM betonmarkets.payment_agent pa;
          ",
        );

        $sth->execute();

        while (my $row = $sth->fetchrow_hashref) {
            $row_count += 1;

            my $loginid      = $row->{loginid};
            my $affiliate_id = $row->{affiliate_id};

            next unless ($affiliate_id);

            my $client = BOM::User::Client->new({loginid => $loginid});

            next if (defined $client->user->affiliate);

            $client->user->set_affiliate_id($affiliate_id);

            $updated_count++;
        }
    });

print "$row_count rows processed, $updated_count affiliate_ids migrated.\n";
