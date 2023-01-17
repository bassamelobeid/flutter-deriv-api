use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client );

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $user = BOM::User->create(
    email    => $client->loginid . '@binary.com',
    password => 'Abcd1234'
);

$user->add_client($client);
$client->binary_user_id($user->id);
$client->user($user);
$client->save;

my $dbh = $client->db->dbic->dbh;

subtest 'Latest' => sub {
    my $latest = $client->documents->latest;

    ok !$latest, 'No POI uploaded';

    my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,?,?,?)';
    my $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'yesterday', 55555, '75bada1e034d13b417083507db47ee4a',
        'none', 'front', undef, 0, 'legacy');

    my $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    my $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $client->documents->_clear_latest;
    $latest = $client->documents->latest;
    ok !$latest, 'POI still uploading';

    $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    my $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client->documents->_clear_latest;
    $latest = $client->documents->latest;
    ok $latest, 'Latest POI found';
};

subtest 'uploaded by Onfido' => sub {
    my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    my $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'yesterday', 1234, 'd00d', 'none', 'front', 'onfido');

    my $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    my $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    my $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);
    $sth_doc_info->execute($client->loginid);

    $client->documents->_build_uploaded;
    my $uploaded = $client->documents->uploaded;

    cmp_deeply $uploaded,
        +{
        proof_of_identity => {
            is_expired  => 1,
            is_pending  => 0,
            is_verified => 1,
            documents   => {
                'CR10000.passport.270744401_front.PNG' => {
                    type        => 'passport',
                    id          => '55555',
                    status      => 'verified',
                    expiry_date => re('\d+'),
                    format      => 'PNG',
                }
            },
            expiry_date => re('\d+'),
        },
        onfido => {
            is_expired  => 1,
            is_pending  => 0,
            is_verified => 1,
            documents   => {
                'CR10000.passport.270744421_front.PNG' => {
                    type        => 'passport',
                    id          => '1234',
                    status      => 'verified',
                    expiry_date => re('\d+'),
                    format      => 'PNG',
                }
            },
            expiry_date => re('\d+'),
        },
        },
        'Expected uploaded documents, onfido is a separate category';
};

done_testing();
