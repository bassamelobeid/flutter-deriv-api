use strict;
use warnings;
use Test::More;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);

use BOM::User::Script::IDVPhotoIdUpdater;
use BOM::User::IdentityVerification;

my $user = BOM::User->create(
    email    => 'idv+photo+id+test@binary.com',
    password => 'pwd'
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $sibling = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$user->add_client($client);
$client->binary_user_id($user->id);
$client->save;
$user->add_client($sibling);
$sibling->binary_user_id($user->id);
$sibling->save;

my $idv_model = BOM::User::IdentityVerification->new(user_id => $user->id);
my $document;

subtest 'Empty tables' => sub {
    $_->delete for @{$client->client_authentication_method};
    ok !$client->fully_authenticated, 'Not fully auth';

    BOM::User::Script::IDVPhotoIdUpdater::run();

    $client = BOM::User::Client->new({loginid => $client->loginid});    # to avoid cache hits

    ok !$client->fully_authenticated, 'Still not fully auth';
};

subtest 'Manipulating IDV' => sub {
    subtest 'No photo id' => sub {
        $idv_model->add_document({
            issuing_country => 'br',
            number          => '90909',
            type            => 'cpf',
            additional      => 'addme',
        });
        $document = $idv_model->get_standby_document();
        $idv_model->update_document_check({
                document_id => $document->{id},
                status      => 'verified',
                messages    => [],
                provider    => 'zaig',
                photo       => [undef]});

        $_->delete for @{$client->client_authentication_method};

        ok !$client->fully_authenticated, 'Not fully auth';

        BOM::User::Script::IDVPhotoIdUpdater::run();

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok !$client->fully_authenticated, 'Still not fully auth';
    };

    subtest 'with octet stream photo id' => sub {
        my $dbh         = $client->db->dbic->dbh;
        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,?,?,?)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'passport', 'octet-stream', 'yesterday', 55555, '1234test', 'none', 'front', undef, 0, 'legacy');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);

        $idv_model->add_document({
            issuing_country => 'br',
            number          => '90909',
            type            => 'cpf',
            additional      => 'addme',
        });
        $document = $idv_model->get_standby_document();
        $idv_model->update_document_check({
                document_id => $document->{id},
                status      => 'verified',
                messages    => [],
                provider    => 'zaig',
                photo       => [$id1]});

        $_->delete for @{$client->client_authentication_method};

        ok !$client->fully_authenticated, 'Not fully auth';

        BOM::User::Script::IDVPhotoIdUpdater::run();

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok !$client->fully_authenticated, 'Still not fully auth';
    };

    subtest 'With photo id' => sub {
        my $dbh         = $client->db->dbic->dbh;
        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,?,?,?)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'yesterday', 55555, '1234testPNG', 'none', 'front', undef, 0, 'legacy');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);
        $idv_model->add_document({
            issuing_country => 'br',
            number          => '90909',
            type            => 'cpf',
            additional      => 'addme',
        });
        $document = $idv_model->get_standby_document();
        $idv_model->update_document_check({
                document_id => $document->{id},
                status      => 'verified',
                messages    => [],
                provider    => 'zaig',
                photo       => [$id1]});

        $_->delete for @{$client->client_authentication_method};

        ok !$client->fully_authenticated, 'Not fully auth';

        BOM::User::Script::IDVPhotoIdUpdater::run();

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok $client->fully_authenticated({landing_company => 'bvi'}), 'Fully auth';

        my $cam = $client->db->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT cam.status, cam.authentication_method_code, cam.client_loginid FROM betonmarkets.client cli LEFT JOIN betonmarkets.client_authentication_method cam ON cam.client_loginid=cli.loginid WHERE cli.binary_user_id = ANY(?)',
                    {Slice => {}},
                    [$user->id]);
            });

        # note the auth method is propagated across siblings by this trigger: betonmarkets.sync_client_authentication_method

        cmp_bag $cam,
            [{
                client_loginid             => $client->loginid,
                authentication_method_code => 'IDV_PHOTO',
                status                     => 'pass',
            },
            {
                client_loginid             => $sibling->loginid,
                authentication_method_code => 'IDV_PHOTO',
                status                     => 'pass',
            }
            ],
            'Expected client auth method after insert';
    };

    subtest 'already authenticated by another method' => sub {
        $_->delete for @{$client->client_authentication_method};

        $client = BOM::User::Client->new({loginid => $client->loginid});    # avoid cache hits

        ok !$client->fully_authenticated, 'Not fully auth';

        $client->set_authentication_and_status('ID_DOCUMENT', 'test');

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok $client->fully_authenticated, 'Fully auth';

        BOM::User::Script::IDVPhotoIdUpdater::run();

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok $client->fully_authenticated, 'Fully auth';

        my $cam = $client->db->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT cam.status, cam.authentication_method_code, cam.client_loginid FROM betonmarkets.client cli LEFT JOIN betonmarkets.client_authentication_method cam ON cam.client_loginid=cli.loginid WHERE cli.binary_user_id = ANY(?)',
                    {Slice => {}},
                    [$user->id]);
            });

        cmp_bag $cam,
            [{
                client_loginid             => $client->loginid,
                authentication_method_code => 'ID_DOCUMENT',
                status                     => 'pass',
            },
            {
                client_loginid             => $sibling->loginid,
                authentication_method_code => 'ID_DOCUMENT',
                status                     => 'pass',
            }
            ],
            'Expected client auth method (ID_DOCUMENT was not overriden)';
    };
};

done_testing();
