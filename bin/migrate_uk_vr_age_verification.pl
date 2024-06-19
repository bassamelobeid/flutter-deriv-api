#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Database::ClientDB;

# This is the SRP for https://redmine.deriv.cloud/issues/25849#New_UK_Sign_Up_flow
# It will copy age verification from MX and MF accounts with gb residence to the VR account,
# and remove unwelcome status from the VR account (previously, all UK VR accounts were created with unwelcome).

my $vrdb = BOM::Database::ClientDB->new({broker_code => 'VRTC'})->db->dbic;
my $mxdb = BOM::Database::ClientDB->new({
        broker_code => 'MX',
        operation   => 'replica'
    })->db->dbic;
my $mfdb = BOM::Database::ClientDB->new({
        broker_code => 'MF',
        operation   => 'replica'
    })->db->dbic;

# note: some old MX records have null binary_user_id
my $query = sub {
    $_->selectall_arrayref(
        "SELECT c.binary_user_id, s.reason FROM betonmarkets.client_status s 
        JOIN betonmarkets.client c ON c.loginid = s.client_loginid 
        WHERE c.residence = 'gb' AND status_code = 'age_verification' AND c.binary_user_id IS NOT NULL", {Slice => {}});
};

my %age_verified;
$age_verified{$_->{binary_user_id}} = $_->{reason} for $mxdb->run(fixup => $query)->@*;
$age_verified{$_->{binary_user_id}} = $_->{reason} for $mfdb->run(fixup => $query)->@*;

for my $id (keys %age_verified) {
    $vrdb->run(
        fixup => sub {
            my $sth = $_->prepare_cached(
                "INSERT INTO betonmarkets.client_status (status_code, client_loginid, reason) SELECT 'age_verification', loginid, ? FROM betonmarkets.client WHERE binary_user_id = ? ON CONFLICT DO NOTHING"
            );
            $sth->execute($age_verified{$id}, $id);
        });
}

my $loginids = $vrdb->run(
    fixup => sub {
        $_->selectcol_arrayref(
            "DELETE FROM betonmarkets.client_status WHERE status_code= 'unwelcome' AND reason = 'Pending proof of age' RETURNING client_loginid");
    });

print "$_\n" for @$loginids;
