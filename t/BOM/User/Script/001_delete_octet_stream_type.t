use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Platform::S3Client;
use BOM::User::Script::DeleteOctetStreamType;

my $client_dbic = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    })->db->dbic;

my $filename_s3;

my $s3_client_mock = Test::MockModule->new('BOM::Platform::S3Client');
$s3_client_mock->mock(
    'delete',
    sub {
        shift;
        $filename_s3 = shift;
        return $filename_s3;
    });

subtest 'testing deletion of octetstream type' => sub {
    my $email = 'test_file_deleted+01@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $file_type      = 'octet-stream';
    my $doctype        = 'passport';
    my $lifetime_valid = 1;
    my $loginid        = $client->loginid;

    my $upload_info;
    $upload_info = $client->db->dbic->run(
        ping => sub {
            $_->selectrow_hashref(
                'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                undef, $loginid, $doctype, $file_type,      undef, '', '75bada1e034d13b417083507db47ee4b',
                '',    '',       undef,    $lifetime_valid, 'bo',
            );
        });

    is $upload_info->{file_name}, 'CR10000.passport.270744401.octet-stream', 'Filename is correct, with octet-stream type';

    my $docs = $client_dbic->run(
        fixup => sub {
            $_->selectall_arrayref(<<'SQL', undef);
SELECT file_name, id
FROM betonmarkets.client_authentication_document
WHERE file_name like '%octet-stream%'
SQL
        });

    cmp_bag $docs, [['CR10000.passport.270744401.octet-stream', '270744401']], 'documents found';

    BOM::User::Script::DeleteOctetStreamType::remove_client_authentication_docs_from_S3;

    is $filename_s3, 'CR10000.passport.270744401.octet-stream', 's3 filename populated';

    $docs = $client_dbic->run(
        fixup => sub {
            $_->selectall_arrayref(<<'SQL', undef);
SELECT file_name, id
FROM betonmarkets.client_authentication_document
WHERE file_name like '%octet-stream%'
SQL
        });

    cmp_bag $docs, [], 'no documents found';

};

done_testing;
