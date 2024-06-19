use strict;
use warnings;
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use Date::Utility;
use feature 'say';

=head2 copy_tnc_approval_to_user.pl

Copies t&c approval from client status to user table.

=cut

my $chunk_size = 500;

my $user_db = BOM::Database::UserDB::rose_db()->dbic;

my $collector_db = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
        operation   => 'collector',
    })->db->dbic;

my $brokers = $collector_db->run(
    fixup => sub {
        return $_->selectcol_arrayref('SELECT * FROM betonmarkets.production_servers()');
    });

for my $broker (@$brokers) {
    my $offset = 0;
    my $records;
    my $client_db = BOM::Database::ClientDB->new({broker_code => uc $broker})->db->dbic;

    do {
        say "processing $broker offset $offset";
        $records = $client_db->run(
            fixup => sub {
                $_->selectall_arrayref(
                    "SELECT c.binary_user_id, s.reason, s.last_modified_date 
                  FROM betonmarkets.client_status s 
                  JOIN betonmarkets.client c ON c.loginid = s.client_loginid 
                  WHERE s.status_code = 'tnc_approval' 
                  ORDER by s.id OFFSET ? LIMIT ?", {Slice => {}}, $offset, $chunk_size
                );
            });
        say ' - ' . scalar @$records . ' records';

        for my $record (@$records) {
            $user_db->run(
                fixup => sub {
                    $_->do(
                        "INSERT INTO users.tnc_approval (binary_user_id, version, brand, stamp) 
                        VALUES (?, ?, 'binary', ?) 
                        ON CONFLICT (binary_user_id, version, brand) DO UPDATE SET stamp = CASE WHEN EXCLUDED.stamp < users.tnc_approval.stamp THEN EXCLUDED.stamp ELSE users.tnc_approval.stamp END",
                        undef,
                        @$record{qw/binary_user_id reason last_modified_date/});
                });
        }

        $offset += $chunk_size;

    } while @$records == $chunk_size;
}
