use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client );
use Test::MockModule;

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
    my $now          = Date::Utility->new;
    my $best_date;

    my $SQL_1       = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,?,NULL,?::betonmarkets.client_document_origin)';
    my $sth_doc_new = $dbh->prepare($SQL_1);

    my $SQL_2          = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    my $sth_doc_finish = $dbh->prepare($SQL_2);

    my $SQL_3          = 'UPDATE betonmarkets.client_authentication_document SET verified_date = ? WHERE id = ?';
    my $sth_doc_update = $dbh->prepare($SQL_3);

    subtest 'No POA docs' => sub {
        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->to_be_outdated('proof_of_address'), undef, 'Not getting outdated';
    };

    subtest 'No best date' => sub {
        $best_date = undef;
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'awe4', 'none', 'front', $best_date, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);

        $client->documents->_clear_uploaded;
        $sth_doc_update->execute(undef, $id1);
        is $client->documents->to_be_outdated('proof_of_address'), undef, 'Not getting outdated';
        ok !$client->documents->outdated('proof_of_address'),                         'PoA is not outdated';
        ok !$client->documents->best_poa_date('proof_of_address', 'best_issue_date'), 'undef best issue date';
    };

    subtest 'With outdated best date +100' => sub {
        $best_date = $one_year_ago->minus_time_interval('100d')->date_yyyymmdd;

        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ftag', 'none', 'front', $best_date, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);
        $sth_doc_update->execute(undef, $id1);

        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date')->date_yyyymmdd, $best_date, 'expected best issue date';
        is $client->documents->to_be_outdated('proof_of_address'),                                  undef,      'Not getting outdated';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'),                                           100,        'PoA is outdated by 100 days';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date')->date_yyyymmdd, $best_date, 'expected best verified date';

        $sth_doc_update->execute(undef, $id1);
    };

    subtest 'With outdated poa date +2' => sub {
        $best_date = $one_year_ago->minus_time_interval('2d')->date_yyyymmdd;

        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ddadd', 'none', 'front', $best_date, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);
        $sth_doc_update->execute(undef, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), undef, 'Not getting outdated';
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date')->date_yyyymmdd, $best_date, 'expected best issue date';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'),                                           2,          'PoA is outdated by 2 days';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date')->date_yyyymmdd, $best_date, 'expected best verified date';

        $sth_doc_update->execute(undef, $id1);
    };

    subtest 'With outdated poa date +1' => sub {
        $best_date = $one_year_ago->minus_time_interval('1d')->date_yyyymmdd;

        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ffaf', 'none', 'front', $best_date, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);
        $sth_doc_update->execute(undef, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), undef, 'Not getting outdated';
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date')->date_yyyymmdd,
            $one_year_ago->minus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'),                                           1,          'PoA is outdated by 1 day';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date')->date_yyyymmdd, $best_date, 'expected best verified date';

        # note: don't reset the the verified_date for the next test to pass
    };

    subtest 'With outdated poa date +3' => sub {
        $best_date = $one_year_ago->minus_time_interval('3d')->date_yyyymmdd;

        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'xxasa', 'none', 'front', $best_date, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);
        $sth_doc_update->execute(undef, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), undef, 'Not getting outdated (already outdated)';
        ok $client->documents->outdated('proof_of_address'), 'PoA is outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date')->date_yyyymmdd,
            $one_year_ago->minus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'), 1, 'PoA is outdated by 1 day still';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date')->date_yyyymmdd,
            $one_year_ago->minus_time_interval('1d')->date_yyyymmdd, 'expected best verified date';

        # note: don't reset the the verified_date for the next test to pass
    };

    subtest 'With boundary poa date but rejected' => sub {
        $best_date = $one_year_ago->date_yyyymmdd;

        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'afkee', 'none', 'front', $best_date, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        my $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'rejected\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_update->execute(undef, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), undef, 'Not getting outdated (already outdated)';
        is $client->documents->outdated('proof_of_address'),       1,     'PoA is outdated by 1 day still';
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date')->date_yyyymmdd,
            $one_year_ago->minus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->outdated('proof_of_address'), 1, 'PoA is outdated by 1 day still';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date')->date_yyyymmdd,
            $one_year_ago->minus_time_interval('1d')->date_yyyymmdd, 'expected best verified date';

        # note: don't reset the the verified_date for the next test to pass
    };

    subtest 'With boundary poa date' => sub {
        $best_date = $one_year_ago->date_yyyymmdd;

        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'afk', 'none', 'front', $best_date, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);
        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), 0, 'Getting outdated soon';
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date')->date_yyyymmdd, $best_date, 'expected best issue date';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date')->date_yyyymmdd, $best_date, 'expected best verified date';

        # note: don't reset the the verified_date for the next test to pass
    };

    subtest 'With outdated poa date +3' => sub {
        $best_date = $one_year_ago->minus_time_interval('3d')->date_yyyymmdd;

        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ggasfafaggg', 'none', 'front', $best_date, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);
        $sth_doc_update->execute(undef, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), 0, 'Getting outdated soon';
        is $client->documents->outdated('proof_of_address'),       0, 'PoA is not outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date')->date_yyyymmdd, $one_year_ago->date_yyyymmdd,
            'expected best issue date';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date')->date_yyyymmdd, $one_year_ago->date_yyyymmdd,
            'expected best verified date';

        # note: don't reset the the verified_date for the next test to pass
    };

    subtest 'With valid best date' => sub {
        $best_date = $now->date_yyyymmdd;

        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'yuu', 'none', 'front', $now->date_yyyymmdd, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);
        $sth_doc_update->execute(undef, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date')->date_yyyymmdd, $now->date_yyyymmdd, 'expected best issue date';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->to_be_outdated('proof_of_address'), $now->plus_time_interval('1y')->days_between($now), 'Getting outdated in 1 year';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date')->date_yyyymmdd, $now->date_yyyymmdd,
            'expected best verified date';

        # note: don't reset the the verified_date for the next test to pass
    };

    subtest 'With outdated poa date +3' => sub {
        $best_date = $one_year_ago->minus_time_interval('3d')->date_yyyymmdd;

        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'ggggg', 'none', 'front', $best_date, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);
        $sth_doc_update->execute(undef, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), $now->plus_time_interval('1y')->days_between($now),   'will get outdated soon';
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date')->date_yyyymmdd, $now->date_yyyymmdd, 'expected best issue date';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date')->date_yyyymmdd, $now->date_yyyymmdd,
            'expected best verified date';

        # note: don't reset the the verified_date for the next test to pass
    };

    subtest 'With worse issuance date' => sub {
        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,?,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', $now->minus_time_interval('1d')->date_yyyymmdd,
            1234, 'aasfqs', 'none', 'front', $now->minus_time_interval('1d')->date_yyyymmdd, 'bo');

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
        is $client->documents->to_be_outdated('proof_of_address'), $now->plus_time_interval('1y')->days_between($now), 'Getting outdated in 1 year';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $now->date_yyyymmdd,                'expected best issue date';

        # note: don't reset the the verified_date for the next test to pass
    };

    subtest 'With better issuance date' => sub {
        $best_date = $now->plus_time_interval('1d')->date_yyyymmdd;

        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,?,NULL,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', $now->plus_time_interval('1d')->date_yyyymmdd,
            1234, 'asvsv', 'none', 'front', $now->plus_time_interval('1d')->date_yyyymmdd, 'bo');

        my $id1 = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

        my $sth_doc_info = $dbh->prepare($SQL);
        $sth_doc_info->execute($client->loginid);

        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id1);
        $sth_doc_info->execute($client->loginid);
        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->to_be_outdated('proof_of_address'), $now->plus_time_interval('1y')->plus_time_interval('1d')->days_between($now),
            'Getting outdated in 1 year';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $now->plus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'Drop the boundary doc' => sub {
        my $SQL         = 'UPDATE betonmarkets.client_authentication_document SET status=? WHERE issue_date = ? ';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute('uploaded', $now->minus_time_interval('1y')->date_yyyymmdd);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), $now->plus_time_interval('1y')->plus_time_interval('1d')->days_between($now),
            'will get outdated in 1 year + 1 day';
        is $client->documents->outdated('proof_of_address'), 0, 'PoA is not outdated';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $now->plus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'Drop todays doc' => sub {
        my $SQL         = 'UPDATE betonmarkets.client_authentication_document SET status=? WHERE issue_date = ? ';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute('uploaded', $now->date_yyyymmdd);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), $now->plus_time_interval('1y')->plus_time_interval('1d')->days_between($now),
            'will get outdated in 1 year + 1 day';
        is $client->documents->outdated('proof_of_address'), 0, 'PoA is not outdated';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $now->plus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'Drop best doc' => sub {
        my $SQL         = 'UPDATE betonmarkets.client_authentication_document SET status=? WHERE issue_date = ? ';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute('uploaded', $now->date_yyyymmdd);
        $sth_doc_new->execute('uploaded', $now->plus_time_interval('1d')->date_yyyymmdd);
        $sth_doc_new->execute('uploaded', $now->plus_time_interval('2d')->date_yyyymmdd);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), $now->plus_time_interval('1y')->days_between($now),
            'will get outdated in 1 year - 1 day';
        is $client->documents->outdated('proof_of_address'), 0, 'PoA is not outdated';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $now->minus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'Drop yesterday doc' => sub {
        my $SQL         = 'UPDATE betonmarkets.client_authentication_document SET status=? WHERE issue_date = ? ';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute('uploaded', $now->minus_time_interval('1d')->date_yyyymmdd);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), undef, 'already outdated';
        is $client->documents->outdated('proof_of_address'),       1,     'PoA is outdated';
        is $client->documents->best_issue_date('proof_of_address')->date_yyyymmdd, $one_year_ago->minus_time_interval('1d')->date_yyyymmdd,
            'expected best issue date';
    };

    subtest 'Lifetime valid' => sub {
        my $SQL =
            'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,(?::DATE - INTERVAL \'100 day\')::DATE,TRUE,?::betonmarkets.client_document_origin)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'awe', 'none', 'front', $one_year_ago->date_yyyymmdd, 'bo');
        my $id1 = $sth_doc_new->fetch()->[0];

        $sth_doc_finish->execute($id1);

        $client->documents->_clear_uploaded;
        is $client->documents->best_poa_date('proof_of_address', 'best_issue_date'), undef, 'undef best issue date';

        $sth_doc_update->execute($best_date, $id1);

        $client->documents->_clear_uploaded;
        is $client->documents->to_be_outdated('proof_of_address'), undef, 'will never get outdated';
        ok !$client->documents->outdated('proof_of_address'), 'PoA is not outdated';
        is $client->documents->best_poa_date('proof_of_address', 'best_verified_date'), undef, 'undef best verified date';
    };
};

for my $category (qw/onfido proof_of_identity/) {
    my $SQL         = 'DELETE FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';
    my $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid);

    my $source = 'bo';
    $source = 'onfido' if $category eq 'onfido';

    subtest "Expired $category documents" => sub {
        my $now = Date::Utility->new;

        subtest 'No POI docs' => sub {
            $client->documents->_clear_uploaded;
            ok !$client->documents->expired(1, $category), "$category is not outdated";
            is $client->documents->to_be_expired($category),    undef, 'Not getting expired';
            is $client->documents->best_expiry_date($category), undef, 'No expiry date';
        };

        subtest 'No expiration date' => sub {
            my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,NULL,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 1234, 'awe4', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok !$client->documents->expired(1, $category), "$category is not expired";
            is $client->documents->to_be_expired('proof_of_address'), undef, 'Not getting expired';
            is $client->documents->best_expiry_date($category),       undef, 'No expiry date';
        };

        subtest 'With expired date +100' => sub {
            my $SQL =
                'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE - INTERVAL \'100 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'ftag', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok $client->documents->expired(1, $category), "$category is expired";
            is $client->documents->to_be_expired($category),                   undef,                                            'Already expired';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->minus_time_interval('100d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With expired date +2' => sub {
            my $SQL =
                'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE - INTERVAL \'2 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'ddadd', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok $client->documents->expired(1, $category), "$category is expired";
            is $client->documents->to_be_expired($category),                   undef,                                          'Already expired';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->minus_time_interval('2d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With expired date +1' => sub {
            my $SQL =
                'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE - INTERVAL \'1 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'ddxdd', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok $client->documents->expired(1, $category), "$category is expired";
            is $client->documents->to_be_expired($category),                   undef,                                          'Already expired';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->minus_time_interval('1d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With expired date +3' => sub {
            my $SQL =
                'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE - INTERVAL \'3 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'ddaadd', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok $client->documents->expired(1, $category), "$category is expired";
            is $client->documents->to_be_expired($category),                   undef,                                          'Already expired';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->minus_time_interval('1d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With boundary expiry date (but rejected)' => sub {
            my $SQL = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'ddaaadd', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'rejected\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok $client->documents->expired(1, $category), "$category is expired";
            is $client->documents->to_be_expired($category),                   undef,                                          'Already expired';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->minus_time_interval('1d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With boundary expiry date' => sub {
            my $SQL = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'ddxxdd', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok !$client->documents->expired(1, $category), "$category is not expired";
            is $client->documents->to_be_expired($category),                   0,                   'Expiring soon';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With expired date +3' => sub {
            my $SQL =
                'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE - INTERVAL \'3 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'ddddaadd', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok !$client->documents->expired(1, $category), "$category is not expired";
            is $client->documents->to_be_expired($category),                   0,                   'Expiring soon';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With valid expiry date' => sub {
            my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'utility_bill', 'PNG', $now->date_yyyymmdd, 1234, 'yuu', 'none', 'front', 'bo');

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok !$client->documents->expired(1, $category), "$category is not outdated";
            is $client->documents->to_be_expired($category),                   0,                   'Getting expired soon';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With expired date +3' => sub {
            my $SQL =
                'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE - INTERVAL \'3 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'dddssssdaadd', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok !$client->documents->expired(1, $category), "$category is not expired";
            is $client->documents->to_be_expired($category),                   0,                   'Expiring soon';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'Drop todays doc' => sub {
            my $SQL         = 'UPDATE betonmarkets.client_authentication_document SET status=? WHERE expiration_date = ? ';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute('uploaded', $now->date_yyyymmdd);

            $client->documents->_clear_uploaded;
            ok $client->documents->expired(1, $category), 'document expired';
            is $client->documents->to_be_expired($category),                   undef, "$category already expired";
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->minus_time_interval('1d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With expired date -300' => sub {
            my $SQL =
                'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE + INTERVAL \'300 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'dddssssdaaddassa12333', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok !$client->documents->expired(1, $category), "$category is not expired";
            is $client->documents->to_be_expired($category),                   300, 'Expiring in 300 days';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->plus_time_interval('300d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With expired date -200' => sub {
            my $SQL =
                'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE + INTERVAL \'200 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'test124124', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok !$client->documents->expired(1, $category), "$category is not expired";
            is $client->documents->to_be_expired($category),                   300, 'Expiring in 300 days';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->plus_time_interval('300d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'With expired date -50' => sub {
            my $SQL =
                'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE + INTERVAL \'50 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'best124512', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            ok !$client->documents->expired(1, $category), "$category is not expired";
            is $client->documents->to_be_expired($category),                   300, 'Expiring in 300 days';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->plus_time_interval('300d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'Drop valid docs' => sub {
            my $SQL         = 'UPDATE betonmarkets.client_authentication_document SET status=? WHERE expiration_date >= ? ';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute('uploaded', $now->date_yyyymmdd);

            $client->documents->_clear_uploaded;
            ok $client->documents->expired(1, $category), "$category is expired";
            is $client->documents->to_be_expired($category),                   undef,                                          'already expired';
            is $client->documents->best_expiry_date($category)->date_yyyymmdd, $now->minus_time_interval('1d')->date_yyyymmdd, 'Best expiry date';
        };

        subtest 'Lifetime valid' => sub {
            my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,NULL,?,?,?,?,NULL,TRUE,?::betonmarkets.client_document_origin)';
            my $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 1234, 'awe', 'none', 'front', $source);

            my $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            my $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            my $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);

            $client->documents->_clear_uploaded;
            is $client->documents->to_be_expired($category), undef, 'will never get expired';
            ok !$client->documents->expired(1, $category), "$category is not expired";
            is $client->documents->best_expiry_date($category), undef, 'will never get expired';
        };
    };
}

subtest 'best expiry date' => sub {
    # drop the docs
    my $SQL         = 'UPDATE betonmarkets.client_authentication_document SET status=? ';
    my $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute('uploaded');

    is $client->documents->best_expiry_date(), undef, 'will never get expired';

    my $now = Date::Utility->new;
    $SQL =
        'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE + INTERVAL \'200 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'egwefwe', 'none', 'front', 'onfido');

    my $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    my $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    my $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);
    $sth_doc_info->execute($client->loginid);

    $client->documents->_clear_uploaded;
    is $client->documents->best_expiry_date()->date_yyyymmdd, $now->plus_time_interval('200d')->date_yyyymmdd, 'expires in 200';

    $SQL =
        'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE + INTERVAL \'100 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'wewevwe', 'none', 'front', 'bo');

    $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);
    $sth_doc_info->execute($client->loginid);

    $client->documents->_clear_uploaded;
    is $client->documents->best_expiry_date()->date_yyyymmdd, $now->plus_time_interval('200d')->date_yyyymmdd, 'expires in 200 still';

    $SQL =
        'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE + INTERVAL \'500 day\')::DATE,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'wdvwevwe', 'none', 'front', 'bo');

    $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);
    $sth_doc_info->execute($client->loginid);

    $client->documents->_clear_uploaded;
    is $client->documents->best_expiry_date()->date_yyyymmdd, $now->plus_time_interval('500d')->date_yyyymmdd, 'expires in 500';

    $SQL =
        'SELECT * FROM betonmarkets.start_document_upload(?,?,?,(?::DATE + INTERVAL \'500 day\')::DATE,?,?,?,?,NULL,?,?::betonmarkets.client_document_origin)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', $now->date_yyyymmdd, 1234, 'QFQWFQW', 'none', 'front', 1, 'bo');

    $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);

    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);
    $sth_doc_info->execute($client->loginid);

    $client->documents->_clear_uploaded;
    is $client->documents->best_expiry_date(), undef, 'lifetime valid doc';

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

    $SQL = "UPDATE betonmarkets.client_authentication_document SET verified_date=NOW() - INTERVAL '1 year' - INTERVAL '1 day' WHERE id = ?";
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

    $SQL            = "UPDATE betonmarkets.client_authentication_document SET verified_date=NOW() - INTERVAL '1 year' WHERE id = ?";
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client->documents->_clear_uploaded;
    is $client->get_poa_status, 'verified', 'POA status = verified';
};

subtest 'POA state machine MF account' => sub {
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    my $user = BOM::User->create(
        email    => $client_mf->loginid . '@binary.com',
        password => 'RandomPassword1234'
    );

    $user->add_client($client_mf);
    $client_mf->binary_user_id($user->id);
    $client_mf->user($user);
    $client_mf->save;

    is $client_mf->get_poa_status, 'none', 'POA status = none';

    my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin)';
    my $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client_mf->loginid, 'utility_bill', 'PNG', 'yesterday', 1234, 'z33z', 'none', 'front', 'bo');

    my $id1 = $sth_doc_new->fetch()->[0];

    $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'uploaded\'::status_type)';
    my $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client_mf->documents->_clear_uploaded;
    is $client_mf->get_poa_status, 'pending', 'POA status = pending';

    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'rejected\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client_mf->documents->_clear_uploaded;
    is $client_mf->get_poa_status, 'rejected', 'POA status = rejected';

    $client_mf->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client_mf->documents->_clear_uploaded;
    is $client_mf->get_poa_status, 'verified', 'POA status = verified';

    $SQL = "UPDATE betonmarkets.client_authentication_document SET verified_date=NOW() - INTERVAL '1 year' - INTERVAL '1 day' WHERE id = ?";
    $client_mf->aml_risk_classification('low');
    $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1);

    $client_mf->documents->_clear_uploaded;

    is $client_mf->get_poa_status, 'verified', 'POA status = verified - verified_date is older than 1 year';

    $client_mf->aml_risk_classification('high');
    $client_mf->documents->_clear_uploaded;

    is $client_mf->get_poa_status, 'expired', 'POA status = expired - verified_date is older than 1 year and high risk';

};

subtest 'to_be_expired' => sub {
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

    my $doc_mock = Test::MockModule->new(ref($client->documents));
    my $uploaded = {};

    $doc_mock->mock(
        'uploaded',
        sub {
            return $uploaded;
        });

    $uploaded = {
        proof_of_identity => {
            to_be_expired => 100,
        },
        onfido => {
            to_be_expired => 300,
        },
    };

    $client->documents->_clear_uploaded;
    is $client->documents->to_be_expired, 300, 'Expires in 300';

    $uploaded = {
        proof_of_identity => {
            to_be_expired => 400,
        },
        onfido => {
            to_be_expired => 200,
        },
    };

    $client->documents->_clear_uploaded;
    is $client->documents->to_be_expired, 400, 'Expires in 400';

    $uploaded = {
        proof_of_identity => {
            to_be_expired => 400,
        },
        onfido => {
            to_be_expired  => 200,
            lifetime_valid => 1,
        },
    };

    $client->documents->_clear_uploaded;
    is $client->documents->to_be_expired, undef, 'never expires';

    $uploaded = {
        proof_of_identity => {
            to_be_expired  => 300,
            lifetime_valid => 1,
        },
        onfido => {
            to_be_expired => 100,
        },
    };

    $client->documents->_clear_uploaded;
    is $client->documents->to_be_expired, undef, 'never expires';

    $doc_mock->unmock_all;
};

subtest 'Expiration Look Ahead' => sub {
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

    my $doc_mock = Test::MockModule->new(ref($client->documents));
    my $uploaded = {};

    $doc_mock->mock(
        'uploaded',
        sub {
            return $uploaded;
        });

    $uploaded = {
        proof_of_identity => {
            to_be_expired => -100,
        },
        onfido => {
            to_be_expired => -300,
        },
        proof_of_address => {
            to_be_expired => -10,
        }};

    $client->documents->_clear_uploaded;
    ok !$client->documents->expiration_look_ahead(7), 'Not expiring within 7 days';

    $uploaded = {
        proof_of_identity => {
            to_be_expired => -100,
        },
        onfido => {
            to_be_expired => -300,
        },
        proof_of_address => {
            to_be_outdated => -10,
        }};

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(10), 'Expired within 10 days';

    $client->documents->_clear_uploaded;
    ok !$client->documents->expiration_look_ahead(200, [], []), 'No categories were specified';

    $client->documents->_clear_uploaded;
    ok !$client->documents->expiration_look_ahead(200, ['proof_of_identity', 'onfido'], 'gargabe'), 'POI does not expire within 200 days';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(300, ['proof_of_identity', 'onfido'], 'gargabe'), 'POI expires within 301 days';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(301, ['proof_of_identity', 'onfido'], 'gargabe'), 'POI expires within 300 days';

    $client->documents->_clear_uploaded;
    ok !$client->documents->expiration_look_ahead(299, ['proof_of_identity', 'onfido'], 'gargabe'), 'POI does not expire within 299 days';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(200, ['proof_of_identity', 'onfido'], 'proof_of_address'), 'POA get outdated within 200 days';

    $client->documents->_clear_uploaded;
    ok !$client->documents->expiration_look_ahead(10, ['proof_of_identity', 'onfido'], 'gargabe'), 'POI does not expire within 10 days';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(10, undef, 'proof_of_address'), 'POA expires within 10 days';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(11, undef, 'proof_of_address'), 'POA expires within 11 days';

    $client->documents->_clear_uploaded;
    ok !$client->documents->expiration_look_ahead(9, undef, 'proof_of_address'), 'POA does not expire within 9 days';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(10, ['garbage'], 'proof_of_address'), 'POA expires within 10 days';

    $client->documents->_clear_uploaded;
    ok !$client->documents->expiration_look_ahead(10, ['garbage'], 'garbage'), 'garbage does not expires within 10 days';

    $uploaded = {
        garbage => {
            to_be_expired => 0,
        }};

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(10, ['garbage'], 'garbage'), 'garbage expires today';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(0, ['garbage'], 'garbage'), 'garbage expires today';

    $client->documents->_clear_uploaded;
    ok !$client->documents->expiration_look_ahead(0, [], 'garbage'), 'garbage does not get outdated today';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(10, ['garbage'], 'more_garbage'), 'garbage expires today';

    $uploaded = {
        garbage => {
            to_be_outdated => 0,
        }};

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(10, ['garbage'], 'garbage'), 'garbage is outdated today';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(0, ['garbage'], 'garbage'), 'garbage is outdated today';

    $client->documents->_clear_uploaded;
    ok !$client->documents->expiration_look_ahead(0, ['garbage'], 'more_garbage'), 'garbage does not expires today';

    $client->documents->_clear_uploaded;
    ok $client->documents->expiration_look_ahead(0, ['more_garbage'], 'garbage'), 'garbage is outdated today';

};

subtest 'poi look ahead' => sub {
    my $look_ahead = +BOM::User::Client::AuthenticationDocuments::DOCUMENT_EXPIRING_SOON_DAYS_TO_LOOK_AHEAD;
    my $client     = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
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

    my $user_mock = Test::MockModule->new(ref($user));
    my $has_mt5_regulated_account;
    $user_mock->mock(
        'has_mt5_regulated_account',
        sub {
            return $has_mt5_regulated_account;
        });

    my $docs_mock = Test::MockModule->new(ref($client->documents));
    my $to_be_expired;
    $docs_mock->mock(
        'to_be_expired',
        sub {
            return $to_be_expired;
        });

    ok !$client->documents->poi_expiration_look_ahead(), 'No mt5 regulated accounts';

    $has_mt5_regulated_account = 1;

    ok !$client->documents->poi_expiration_look_ahead(), 'undef to be expired';

    $to_be_expired = $look_ahead + 1;

    ok !$client->documents->poi_expiration_look_ahead(), 'not within the threshold';

    $to_be_expired = $look_ahead;

    ok $client->documents->poi_expiration_look_ahead(), 'exactly on the limit';

    $to_be_expired = $look_ahead - 1;

    ok $client->documents->poi_expiration_look_ahead(), 'within the threshold';

    $user_mock->unmock_all;
    $docs_mock->unmock_all;
};

subtest 'poa look ahead' => sub {
    my $look_ahead = +BOM::User::Client::AuthenticationDocuments::DOCUMENT_EXPIRING_SOON_DAYS_TO_LOOK_AHEAD;
    my $client     = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
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

    my $user_mock = Test::MockModule->new(ref($user));
    my $has_mt5_regulated_account;
    $user_mock->mock(
        'has_mt5_regulated_account',
        sub {
            return $has_mt5_regulated_account;
        });

    my $docs_mock = Test::MockModule->new(ref($client->documents));
    my $to_be_outdated;
    $docs_mock->mock(
        'to_be_outdated',
        sub {
            return $to_be_outdated;
        });

    ok !$client->documents->poa_outdated_look_ahead(), 'No mt5 regulated accounts';

    $has_mt5_regulated_account = 1;

    ok !$client->documents->poa_outdated_look_ahead(), 'undef to be outdated';

    $to_be_outdated = $look_ahead + 1;

    ok !$client->documents->poa_outdated_look_ahead(), 'not within the threshold';

    $to_be_outdated = $look_ahead;

    ok $client->documents->poa_outdated_look_ahead(), 'exactly on the limit';

    $to_be_outdated = $look_ahead - 1;

    ok $client->documents->poa_outdated_look_ahead(), 'within the threshold';

    $user_mock->unmock_all;
    $docs_mock->unmock_all;
};

subtest 'stash' => sub {
    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    my $user = BOM::User->create(
        email    => 'stash-of-documents@binary.com',
        password => 'Abcd1234'
    );

    $user->add_client($cr);
    $user->add_client($mf);
    $user->add_client($vr);

    $cr->binary_user_id($user->id);
    $cr->user($user);
    $cr->save;

    $mf->binary_user_id($user->id);
    $mf->user($user);
    $mf->save;

    $vr->binary_user_id($user->id);
    $vr->user($user);
    $vr->save;

    # seed a bit
    upload($cr, '123', 'national_identity_card', 'uploaded', 'mychecksum1',  'client', 'front', '2020-10-10', 'br');
    upload($cr, '123', 'national_identity_card', 'uploaded', 'mychecksum2',  'client', 'back',  '2020-10-10', 'br');
    upload($cr, '123', 'national_identity_card', 'uploaded', 'mychecksum3',  'bo',     'front', '2000-10-10', 'br');
    upload($cr, '123', 'national_identity_card', 'uploaded', 'mychecksum4',  'bo',     'back',  '2000-10-10', 'br');
    upload($vr, '123', 'national_identity_card', 'uploaded', 'mychecksum5',  'client', 'front', '1999-10-10', 'br');
    upload($vr, '123', 'national_identity_card', 'uploaded', 'mychecksum6',  'client', 'back',  '1999-10-10', 'br');
    upload($mf, '123', 'national_identity_card', 'verified', 'mychecksum7',  'client', 'front', '1998-10-10', 'br');
    upload($mf, '123', 'national_identity_card', 'verified', 'mychecksum8',  'client', 'back',  '1998-10-10', 'br');
    upload($mf, '123', 'national_identity_card', 'uploaded', 'mychecksum9',  'client', 'front', '2021-10-10', 'br');
    upload($mf, '123', 'national_identity_card', 'uploaded', 'mychecksum10', 'client', 'back',  '2021-10-10', 'br');
    upload($mf, '123', 'passport',               'uploaded', 'mychecksum11', 'client', 'front', '2021-10-10', 'br');
    upload($mf, '123', 'passport',               'uploaded', 'mychecksum12', 'client', 'back',  '2021-10-10', 'br');
    upload($mf, '123', 'bank_statement',         'uploaded', 'mychecksum13', 'client', 'front', '1997-10-10', 'br');
    upload($mf, '123', 'bank_statement',         'uploaded', 'mychecksum14', 'client', 'back',  '1997-10-10', 'br');
    upload($cr, '123', 'selfie_with_id',         'uploaded', 'mychecksum15', 'client', 'front', '1997-10-10', 'br');
    upload($cr, '123', 'selfie_with_id',         'uploaded', 'mychecksum16', 'client', 'back',  '1997-10-10', 'br');
    upload($vr, '123', 'poa',                    'uploaded', 'mychecksum17', 'client', 'front', '1999-10-10', 'br');
    upload($vr, '123', 'poa',                    'uploaded', 'mychecksum18', 'client', 'back',  '1999-10-10', 'br');

    my $stash = [
        map {
            {
                client_loginid  => $_->{client_loginid},
                document_id     => $_->{document_id},
                issuing_country => $_->{issuing_country},
                document_type   => $_->{document_type},
                origin          => $_->{origin},
                status          => $_->{status},
                file_name       => $_->{file_name},
            }
        } $cr->documents->stash('uploaded', 'client', ['national_identity_card', 'passport'])->@*
    ];

    cmp_bag $stash,
        [{
            file_name       => re('front'),
            client_loginid  => $cr->loginid,
            document_type   => 'national_identity_card',
            issuing_country => 'br',
            origin          => 'client',
            document_id     => '123',
            status          => 'uploaded'
        },
        {
            document_type   => 'national_identity_card',
            document_id     => '123',
            status          => 'uploaded',
            origin          => 'client',
            issuing_country => 'br',
            file_name       => re('back'),
            client_loginid  => $cr->loginid,
        },
        {
            file_name       => re('back'),
            client_loginid  => $mf->loginid,
            document_type   => 'national_identity_card',
            document_id     => '123',
            status          => 'uploaded',
            issuing_country => 'br',
            origin          => 'client'
        },
        {
            client_loginid  => $mf->loginid,
            file_name       => re('front'),
            document_type   => 'passport',
            origin          => 'client',
            issuing_country => 'br',
            document_id     => '123',
            status          => 'uploaded'
        },
        {
            file_name       => re('back'),
            client_loginid  => $mf->loginid,
            origin          => 'client',
            issuing_country => 'br',
            status          => 'uploaded',
            document_id     => '123',
            document_type   => 'passport'
        },
        {
            origin          => 'client',
            issuing_country => 'br',
            document_id     => '123',
            status          => 'uploaded',
            document_type   => 'national_identity_card',
            client_loginid  => $mf->loginid,
            file_name       => re('front'),
        }
        ],
        'Expected stash';

    $stash = [
        map {
            {
                client_loginid  => $_->{client_loginid},
                document_id     => $_->{document_id},
                issuing_country => $_->{issuing_country},
                document_type   => $_->{document_type},
                origin          => $_->{origin},
                status          => $_->{status},
                file_name       => $_->{file_name},
            }
        } $cr->documents->stash('uploaded', 'client', ['passport'])->@*
    ];

    cmp_bag $stash,
        [{
            origin          => 'client',
            document_type   => 'passport',
            status          => 'uploaded',
            issuing_country => 'br',
            client_loginid  => $mf->loginid,
            file_name       => re('front'),
            document_id     => '123'
        },
        {
            file_name       => re('back'),
            client_loginid  => $mf->loginid,
            document_id     => '123',
            issuing_country => 'br',
            status          => 'uploaded',
            origin          => 'client',
            document_type   => 'passport'
        },
        ],
        'Expected stash';

    $stash = [
        map {
            {
                client_loginid  => $_->{client_loginid},
                document_id     => $_->{document_id},
                issuing_country => $_->{issuing_country},
                document_type   => $_->{document_type},
                origin          => $_->{origin},
                status          => $_->{status},
                file_name       => $_->{file_name},
            }
        } $cr->documents->stash('uploaded', 'bo', ['passport'])->@*
    ];

    cmp_bag $stash, [], 'Expected stash';

    $stash = [
        map {
            {
                client_loginid  => $_->{client_loginid},
                document_id     => $_->{document_id},
                issuing_country => $_->{issuing_country},
                document_type   => $_->{document_type},
                origin          => $_->{origin},
                status          => $_->{status},
                file_name       => $_->{file_name},
            }
        } $cr->documents->stash('uploaded', 'legacy', ['passport'])->@*
    ];

    cmp_bag $stash, [], 'Expected stash';

    $stash = [
        map {
            {
                client_loginid  => $_->{client_loginid},
                document_id     => $_->{document_id},
                issuing_country => $_->{issuing_country},
                document_type   => $_->{document_type},
                origin          => $_->{origin},
                status          => $_->{status},
                file_name       => $_->{file_name},
            }
        } $cr->documents->stash('verified', 'client', ['passport'])->@*
    ];

    cmp_bag $stash, [], 'Expected stash';

    $stash = [
        map {
            {
                client_loginid  => $_->{client_loginid},
                document_id     => $_->{document_id},
                issuing_country => $_->{issuing_country},
                document_type   => $_->{document_type},
                origin          => $_->{origin},
                status          => $_->{status},
                file_name       => $_->{file_name},
            }
        } $cr->documents->stash('verified', 'client', ['national_identity_card', 'passport'])->@*
    ];

    cmp_bag $stash,
        [{
            status          => 'verified',
            document_type   => 'national_identity_card',
            origin          => 'client',
            document_id     => '123',
            file_name       => re('front'),
            client_loginid  => $mf->loginid,
            issuing_country => 'br'
        },
        {
            status          => 'verified',
            document_type   => 'national_identity_card',
            origin          => 'client',
            document_id     => '123',
            file_name       => re('back'),
            client_loginid  => $mf->loginid,
            issuing_country => 'br'
        },
        ],
        'Expected stash';

    $stash = [
        map {
            {
                client_loginid  => $_->{client_loginid},
                document_id     => $_->{document_id},
                issuing_country => $_->{issuing_country},
                document_type   => $_->{document_type},
                origin          => $_->{origin},
                status          => $_->{status},
                file_name       => $_->{file_name},
            }
        } $cr->documents->stash('uploaded', 'client', ['poa', 'bank_statement'])->@*
    ];

    cmp_bag $stash,
        [{
            status          => 'uploaded',
            document_type   => 'bank_statement',
            origin          => 'client',
            document_id     => '123',
            file_name       => re('front'),
            client_loginid  => $mf->loginid,
            issuing_country => 'br'
        },
        {
            status          => 'uploaded',
            document_type   => 'bank_statement',
            origin          => 'client',
            document_id     => '123',
            file_name       => re('back'),
            client_loginid  => $mf->loginid,
            issuing_country => 'br'
        },
        ],
        'Expected stash';
};

sub upload {
    my ($client, $document_id, $type, $status, $checksum, $origin, $side, $upload_date, $country) = @_;

    my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,NULL,?,?,?,?,NULL,NULL,?::betonmarkets.client_document_origin, ?)';
    my $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, $type, 'PNG', $document_id, $checksum, 'none', $side, $origin, $country);

    my $id1 = $sth_doc_new->fetch()->[0];
    $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

    my $sth_doc_info = $dbh->prepare($SQL);
    $sth_doc_info->execute($client->loginid);
    $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, ?::status_type)';
    my $sth_doc_finish = $dbh->prepare($SQL);
    $sth_doc_finish->execute($id1, $status);

    $SQL = 'UPDATE betonmarkets.client_authentication_document SET upload_date = ? WHERE id = ?';

    my $sth_doc_upd = $dbh->prepare($SQL);
    $sth_doc_upd->execute($upload_date, $id1);

    return $id1;
}

done_testing();
