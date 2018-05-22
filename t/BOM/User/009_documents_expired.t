#!perl

use strict;
use warnings;

use Test::More;

use BOM::User::Client;
use Date::Utility;
use BOM::Database::ClientDB;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client top_up);

my $client = create_client();
$client->set_default_account('USD');
$client->save();
my $dbic = $client->db->dbic;
## Testing expiration with the first row null
my $date = Date::Utility->today()->plus_time_interval('1d')->date;

my $id1 = $dbic->run(
    fixup => sub {
        my $sth = $_->prepare(q{select * from betonmarkets.start_document_upload(?,'proofaddress','PNG',null,'12345',null)});
        $sth->execute($client->loginid);
        return $sth->fetchrow_hashref;
    });

my $id2 = $dbic->run(
    fixup => sub {
        my $sth = $_->prepare(q{select * from betonmarkets.start_document_upload(?,'proofid','PNG',?,'123456',null)});
        $sth->execute($client->loginid, $date);
        return $sth->fetchrow_hashref;
    });
$client = BOM::User::Client->new({loginid => $client->loginid});
is $client->documents_expired(), undef, "document is expired";

## Testing expiration with the first row with a valid date and the second expired
$date = Date::Utility->today()->minus_time_interval('1d')->date;

$dbic->run(
    fixup => sub {
        my $sth = $_->prepare(q{update betonmarkets.client_authentication_document set expiration_date = ? where id = ?});
        $sth->execute($date, $id1->{start_document_upload});
    });
$client = BOM::User::Client->new({loginid => $client->loginid});
is $client->documents_expired(), undef,  "document is expired";

## Testing expiration with the 2 valid dates
$dbic->run(
    fixup => sub {
        my $sth = $_->prepare(q{update betonmarkets.client_authentication_document set expiration_date = ? where id = ?});
        $sth->execute($date, $id2->{start_document_upload});
    });
$client = BOM::User::Client->new({loginid => $client->loginid});
is $client->documents_expired(), 1,  "document is NOT expired";

done_testing();
