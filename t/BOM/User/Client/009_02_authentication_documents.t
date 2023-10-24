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

    $client->documents->_clear_uploaded;
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

subtest 'uploaded by IDV' => sub {
    my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    my $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'yesterday', 1234, 'z33z', 'none', 'front', 'idv');

    my $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    my $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    my $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);
    $sth_doc_info->execute($client->loginid);

    $client = BOM::User::Client->new({loginid => $client->loginid});
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
        idv => {
            is_expired  => 1,
            is_pending  => 0,
            is_verified => 1,
            documents   => {
                'CR10000.passport.270744441_front.PNG' => {
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
        'Expected uploaded documents, IDV is a separate category';
};

subtest 'Outdated documents' => sub {
    my $one_year_ago = Date::Utility->new->minus_time_interval('1y');

    subtest 'No POA docs' => sub {
        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
    };

    subtest 'No issuance date' => sub {
        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'awe4', 'none', 'front', 'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'),        'PoA is not outdated';
        ok !$client->documents->best_issue_date('proof_of_address'), 'undef best issue date';
    };

    subtest 'With outdated issuance date +100' => sub {
        my $SQL =
            'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,(?::DATE - INTERVAL \'100 day\')::DATE,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ftag', 'none', 'front', $one_year_ago->date_yyyymmdd,
            'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'), 100, 'PoA is outdated by 100 days';

        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $one_year_ago->minus_time_interval('100d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'With outdated issuance date +2' => sub {
        my $SQL =
            'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,(?::DATE - INTERVAL \'2 day\')::DATE,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ddadd', 'none', 'front', $one_year_ago->date_yyyymmdd,
            'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'), 2, 'PoA is outdated by 2 days';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $one_year_ago->minus_time_interval('2d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'With outdated issuance date +1' => sub {
        my $SQL =
            'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,(?::DATE - INTERVAL \'1 day\')::DATE,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ffaf', 'none', 'front', $one_year_ago->date_yyyymmdd,
            'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'), 1, 'PoA is outdated by 1 day';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $one_year_ago->minus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'With outdated issuance date +3' => sub {
        my $SQL =
            'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,(?::DATE - INTERVAL \'3 day\')::DATE,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'xxasa', 'none', 'front', $one_year_ago->date_yyyymmdd,
            'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'), 1, 'PoA is outdated by 1 day still';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $one_year_ago->minus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'With boundary issuance date but rejected' => sub {
        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,?,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'afkee', 'none', 'front', $one_year_ago->date_yyyymmdd,
            'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'rejected\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'), 1, 'PoA is outdated by 1 day still';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $one_year_ago->minus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'With boundary issuance date' => sub {
        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,?,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'afk', 'none', 'front', $one_year_ago->date_yyyymmdd, 'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'),                       0,                            'PoA is not outdated';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $one_year_ago->date_yyyymmdd, 'expected best issue date';
    };

    subtest 'With outdated issuance date +3' => sub {
        my $SQL =
            'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,(?::DATE - INTERVAL \'3 day\')::DATE,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ggasfafaggg', 'none', 'front',
            $one_year_ago->date_yyyymmdd, 'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'),                       0,                            'PoA is not outdated';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $one_year_ago->date_yyyymmdd, 'expected best issue date';
    };

    my $now = Date::Utility->new;

    subtest 'With valid issuance date' => sub {
        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,?,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'yuu', 'none', 'front', $now->date_yyyymmdd, 'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $now->date_yyyymmdd, 'expected best issue date';
    };

    subtest 'With outdated issuance date +3' => sub {
        my $SQL =
            'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,(?::DATE - INTERVAL \'3 day\')::DATE,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ggggg', 'none', 'front', $one_year_ago->date_yyyymmdd,
            'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'),                       0,                   'PoA is not outdated';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $now->date_yyyymmdd, 'expected best issue date';
    };

    subtest 'Lifetime valid' => sub {
        my $SQL =
            'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,(?::DATE - INTERVAL \'100 day\')::DATE,TRUE,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'awe', 'none', 'front', $one_year_ago->date_yyyymmdd, 'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);

        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_issue_date('proof_of_address'), undef, 'undef best issue date';
    };
};

subtest 'outdated boundary' => sub {
    my $boundary = BOM::User::Client::AuthenticationDocuments::Config::outdated_boundary('test');

    is $boundary, undef, 'no boundary for test category';

    $boundary = BOM::User::Client::AuthenticationDocuments::Config::outdated_boundary('POI');

    is $boundary, undef, 'no boundary for POI category';

    $boundary = BOM::User::Client::AuthenticationDocuments::Config::outdated_boundary('POA');

    my $now = Date::Utility->new();

    is $boundary->date_yyyymmdd, $now->minus_time_interval('1y')->date_yyyymmdd, 'expected boundary for POA';
};

subtest 'Manual docs uploaded at BO' => sub {
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

    is $client->get_manual_poi_status, 'none', 'None Manual POI status';
    is $client->get_poi_status,        'none', 'None POI status';
    cmp_deeply [$client->latest_poi_by], [], 'No POI attempted';

    my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    my $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'yesterday', 1234, 'z33z', 'none', 'front', 'bo');

    my $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    my $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'uploaded\'::status_type)';
    my $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client->documents->_clear_uploaded;
    $client->documents->_clear_latest;

    is $client->get_manual_poi_status, 'pending', 'Pending Manual POI status';
    is $client->get_poi_status,        'pending', 'Pending POI status';
    cmp_deeply [$client->latest_poi_by], ['manual', ignore(), ignore()], 'Manual POI attempted';

    # fully auth
    $client->set_authentication('ID_NOTARIZED', {status => 'pass'});
    $client = BOM::User::Client->new({loginid => $client->loginid});
    is $client->get_manual_poi_status, 'verified', 'Verified Manual POI status';
    is $client->get_poi_status,        'verified', 'Verified POI status';
    cmp_deeply [$client->latest_poi_by], ['manual', ignore(), ignore()], 'Manual POI attempted';

    # making expired a necessity
    $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    my $sth_doc_verified = $dbh->prepare($SQL);
    $sth_doc_verified->execute($id1);

    $client->aml_risk_classification('high');
    $client->save;
    $client = BOM::User::Client->new({loginid => $client->loginid});
    is $client->get_manual_poi_status, 'expired', 'Expired Manual POI status';
    is $client->get_poi_status,        'expired', 'Expired POI status';
    cmp_deeply [$client->latest_poi_by], ['manual', ignore(), ignore()], 'Manual POI attempted';

    # new doc is uploaded

    $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', Date::Utility->new()->plus_time_interval('1y')->date_yyyymmdd,
        1234, 'aaaaa', 'none', 'front', 'bo');

    $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'uploaded\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);
    $client->documents->_clear_uploaded;
    $client->documents->_clear_latest;
    is $client->get_manual_poi_status, 'pending', 'Pending Manual POI status';
    is $client->get_poi_status,        'pending', 'Pending POI status';
    cmp_deeply [$client->latest_poi_by], ['manual', ignore(), ignore()], 'Manual POI attempted';

    # verified once again
    $SQL              = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_verified = $dbh->prepare($SQL);
    $sth_doc_verified->execute($id1);

    $client->aml_risk_classification('high');
    $client->save;
    $client = BOM::User::Client->new({loginid => $client->loginid});
    is $client->get_manual_poi_status, 'verified', 'Verified Manual POI status';
    is $client->get_poi_status,        'verified', 'Verified POI status';
    cmp_deeply [$client->latest_poi_by], ['manual', ignore(), ignore()], 'Manual POI attempted';
};

subtest 'POA state machine' => sub {
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

    is $client->get_poa_status, 'none', 'POA status = none';
    my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    my $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'z33z', 'none', 'front', 'bo');

    my $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    my $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'uploaded\'::status_type)';
    my $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client->documents->_clear_uploaded;
    is $client->get_poa_status, 'pending', 'POA status = pending';

    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'rejected\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client->documents->_clear_uploaded;
    is $client->get_poa_status, 'rejected', 'POA status = rejected';

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client->documents->_clear_uploaded;
    is $client->get_poa_status, 'verified', 'POA status = verified';

    $SQL            = "UPDATE betonmarkets.client_authentication_document SET issue_date=NOW() - INTERVAL '1 year' - INTERVAL '1 day' WHERE id = ?";
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client->documents->_clear_uploaded;
    is $client->get_poa_status, 'expired', 'POA status = expired';

    # upload a 2nd document

    $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 431214, 'qefwee', 'none', 'front', 'bo');

    my $id2 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'uploaded\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id2);

    $client->documents->_clear_uploaded;
    is $client->get_poa_status, 'pending', 'POA status = pending (2nd doc uploaded)';

    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'rejected\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id2);

    $client->documents->_clear_uploaded;
    is $client->get_poa_status, 'expired', 'POA status = expired (2nd doc rejected)';

    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id2);

    $client->documents->_clear_uploaded;
    is $client->get_poa_status, 'expired', 'POA status = expired (2nd doc issue date-less)';

    $SQL            = "UPDATE betonmarkets.client_authentication_document SET issue_date=NOW() - INTERVAL '1 year' WHERE id = ?";
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client->documents->_clear_uploaded;
    is $client->get_poa_status, 'verified', 'POA status = verified';

};

done_testing();
