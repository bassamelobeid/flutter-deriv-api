#!perl

use strict;
use warnings;

use Data::Dumper;
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::User;

use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

my $user_client1 = BOM::User->create(
    email          => 'abc@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $user_client2 = BOM::User->create(
    email          => 'abc1@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_cr  = create_client('CR');
my $client_mlt = create_client('MLT');

$user_client1->add_client($client_cr);
$user_client2->add_client($client_mlt);

$client_cr->set_default_account('USD');
$client_cr->save();

$client_mlt->set_default_account('EUR');
$client_mlt->save();

my %clients_document_expiry = (
    $client_cr->loginid  => 0,
    $client_mlt->loginid => 1,
);

subtest 'client documents expiry' => sub {
    foreach my $loginid (sort keys %clients_document_expiry) {
        my ($test, $SQL, $sth_doc_new, $id1, $id2, $sth_doc_info, $sth_doc_finish, $sth_doc_update, $actual, $expected);

        my $client          = BOM::User::Client->new({loginid => $loginid});
        my $document_expiry = $clients_document_expiry{$loginid};

        my $dbh = $client->db->dbic->dbh;

        subtest 'check for documents_expired' => sub {
            $test = 'BOM::User::Client->documents_expired returns 0 if there are no documents';
            is($client->documents_expired(), 0, $test);

            $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
            $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'yesterday', 55555, '75bada1e034d13b417083507db47ee4a', 'none', 'front');

            $id1 = $sth_doc_new->fetch()->[0];
            $SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';

            $sth_doc_info = $dbh->prepare($SQL);
            $sth_doc_info->execute($client->loginid);

            $actual   = $sth_doc_info->fetchall_arrayref({});
            $expected = [{
                    id     => $id1,
                    status => 'uploading'
                }];
            $test = q{After call to start_document_upload, client has a single document, with an 'uploading' status};
            cmp_deeply($actual, $expected, $test);

            $test = q{BOM::User::Client->documents_expired returns 0 if all documents are in 'uploading' status};
            # This is neeeded to force $client to reload this relationship
            # This will not work: $client->load( with => ['client_authentication_document']);
            $client->client_authentication_document(undef);
            is($client->documents_expired(), 0, $test);

            $test           = q{After call to finish_document_upload, document status changed to 'verified'};
            $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
            $sth_doc_info->execute($client->loginid);
            $actual = $sth_doc_info->fetchall_arrayref({});
            $expected->[0]{status} = 'verified';
            cmp_deeply($actual, $expected, $test);

            $test           = q{BOM::User::Client->documents_expired returns 0 if document in 'verified' status and no expiration date};
            $SQL            = 'UPDATE betonmarkets.client_authentication_document SET expiration_date = ? WHERE id = ?';
            $sth_doc_update = $dbh->prepare($SQL);
            $sth_doc_update->execute(undef, $id1);
            $client->client_authentication_document(undef);
            is($client->documents_expired(), 0, $test);

            $test = q{BOM::User::Client->documents_expired returns 0 if document has future expiration date};
            $sth_doc_update->execute('tomorrow', $id1);
            is($client->documents_expired(), 0, $test);

            $test = qq{BOM::User::Client->documents_expired returns $document_expiry if document has an expiration date of today};
            $sth_doc_update->execute('today', $id1);
            $client->client_authentication_document(undef);
            is($client->documents_expired(), $document_expiry, $test);

            $test =
                qq{BOM::User::Client->documents_expired returns $document_expiry depending if expiration date check is required for document that has an expiration date of yesterday};
            $sth_doc_update->execute('yesterday', $id1);
            $client->client_authentication_document(undef);
            is($client->documents_expired(), $document_expiry, $test);

            $test = q{BOM::User::Client->documents_expired returns 0 if document has an expiration date of the far future};
            $sth_doc_update->execute('2999-01-01', $id1);
            $client->client_authentication_document(undef);
            is($client->documents_expired(), 0, $test);

            $test = q{BOM::User::Client->documents_expired returns 0 because there is at least one non-expired document};
            $sth_doc_update->execute('epoch', $id1);
            $client->client_authentication_document(undef);
            is($client->documents_expired(), 0, $test);

            $test = q{BOM::User::Client->documents_expired returns 0 if all documents have no expiration date};
## Create a second document
            $sth_doc_new->execute($client->loginid, 'passport', 'PNG', undef, 66666, '204a5098dac0dc176c88e4ab5312dbd5', 'none', 'front');
            $id2 = $sth_doc_new->fetch()->[0];

            $SQL = 'SELECT COUNT(*) from betonmarkets.client_authentication_document WHERE client_loginid = ?';
            my $doc_nums = $dbh->prepare($SQL);
            $doc_nums->execute($client->loginid);
            my $total_docs = $doc_nums->fetchrow_array();

            is($total_docs, 2, 'Two documents uploaded');

            $sth_doc_finish->execute($id2);
            $SQL = 'UPDATE betonmarkets.client_authentication_document SET expiration_date = null WHERE client_loginid = ?';
            $dbh->do($SQL, undef, $client->loginid);
            $client->client_authentication_document(undef);
            is($client->documents_expired(), 0, $test);

            $test =
                qq{BOM::User::Client->documents_expired returns $document_expiry depending if expiration check is required and if only some document are expired};
            $sth_doc_update->execute('yesterday', $id2);
            $client->client_authentication_document(undef);
            is($client->documents_expired(), $document_expiry, $test);

            $test = q{BOM::User::Client->documents_expired returns 0 if only all documents expire in the future};
            $sth_doc_update->execute('tomorrow', $id1);
            $sth_doc_update->execute('tomorrow', $id2);
            $client->client_authentication_document(undef);
            is($client->documents_expired(), 0, $test);

            $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
            $sth_doc_new = $dbh->prepare($SQL);
            $sth_doc_new->execute($client->loginid, 'bankstatement', 'PNG', 'yesterday', 65555, '75bada1e034d13b417083507db47ee4b', 'none', 'front');
            $id1            = $sth_doc_new->fetch()->[0];
            $SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
            $sth_doc_finish = $dbh->prepare($SQL);
            $sth_doc_finish->execute($id1);
        };
    }

    subtest 'check for document_expired of duplicate_acount' => sub {
        my $user_client_mf = BOM::User->create(
            email          => 'abcdef@binary.com',
            password       => BOM::User::Password::hashpw('jskjd8292922'),
            email_verified => 1,
        );
        my $mf_client = create_client('MF');
        $user_client_mf->add_client($mf_client);
        $mf_client->status->set('duplicate_account');
        ok $mf_client->status->duplicate_account, "MF Account is set as duplicate_account";
        my $mf_client_2 = create_client('MF');
        $user_client_mf->add_client($mf_client_2);
        $mf_client_2->status->setnx('age_verification', 'Darth Vader', 'Test Case');
        ok $mf_client_2->status->age_verification, "Age verified by other sources";

        my ($doc) = $mf_client_2->add_client_authentication_document({
            file_name                  => $mf_client_2->loginid . '.passport.' . Date::Utility->new->epoch . '.pdf',
            document_type              => "passport",
            document_format            => "PDF",
            document_path              => '/tmp/test.pdf',
            expiration_date            => Date::Utility->new()->plus_time_interval('1d')->date,
            authentication_method_code => 'ID_DOCUMENT',
            checksum                   => '120EA8A25E5D487BF68B5F7096440019'
        });
        $doc->status('verified');
        $mf_client_2->save;
        $mf_client_2->load;
        ok !$mf_client_2->documents_expired, "Documents with status of 'verified' are valid";
        $mf_client_2->status->set('duplicate_account');
        ok $mf_client_2->status->duplicate_account, "MF2 Account is set as duplicate_account";
        $mf_client->status->clear_duplicate_account;
        ok !$mf_client->status->duplicate_account, "MF Account is enabled now.";

        ok !$mf_client->documents_expired, "Documents with status of 'verified' are valid";
        $doc->expiration_date('2010-10-10');
        $doc->save;
        $doc->load;
        ok $mf_client->documents_expired, "If Duplicate account's document expires, documents are not valid anymore for sibling too.";
    };
};

subtest 'documents uploaded' => sub {
    my $documents_mlt = $client_mlt->documents_uploaded();

    my $document_hash_mlt = {
        proof_of_address => {
            documents => {
                $client_mlt->loginid
                    . ".bankstatement.270744521_front.PNG" => {
                    expiry_date =>
                        $documents_mlt->{proof_of_address}{documents}{$client_mlt->loginid . ".bankstatement.270744521_front.PNG"}{expiry_date},
                    format => "PNG",
                    id     => 65555,
                    status => "verified",
                    type   => "bankstatement",
                    },
            },
            is_pending => 1,
        },
        proof_of_identity => {
            documents => {
                $client_mlt->loginid
                    . ".passport.270744481_front.PNG" => {
                    expiry_date =>
                        $documents_mlt->{proof_of_identity}{documents}{$client_mlt->loginid . ".passport.270744481_front.PNG"}{expiry_date},
                    format => "PNG",
                    id     => 55555,
                    status => "verified",
                    type   => "passport",
                    },
                $client_mlt->loginid
                    . ".passport.270744501_front.PNG" => {
                    expiry_date =>
                        $documents_mlt->{proof_of_identity}{documents}{$client_mlt->loginid . ".passport.270744501_front.PNG"}{expiry_date},
                    format => "PNG",
                    id     => 66666,
                    status => "verified",
                    type   => "passport",
                    },
            },
            is_expired  => 0,
            expiry_date => $documents_mlt->{proof_of_identity}{documents}{$client_mlt->loginid . ".passport.270744501_front.PNG"}{expiry_date},
        },
    };

    cmp_deeply($documents_mlt, $document_hash_mlt, 'correct structure for client documents');
    my $documents_cr = $client_cr->documents_uploaded();

    my $document_hash_cr = {
        proof_of_address => {
            documents => {
                $client_cr->loginid
                    . ".bankstatement.270744461_front.PNG" => {
                    expiry_date =>
                        $documents_cr->{proof_of_address}{documents}{$client_cr->loginid . ".bankstatement.270744461_front.PNG"}{expiry_date},
                    format => "PNG",
                    id     => 65555,
                    status => "verified",
                    type   => "bankstatement",
                    },
            },
            is_pending => 1,
        },
        proof_of_identity => {
            documents => {
                $client_cr->loginid
                    . ".passport.270744421_front.PNG" => {
                    expiry_date => $documents_cr->{proof_of_identity}{documents}{$client_cr->loginid . ".passport.270744421_front.PNG"}{expiry_date},
                    format      => "PNG",
                    id          => 55555,
                    status      => "verified",
                    type        => "passport",
                    },
                $client_cr->loginid
                    . ".passport.270744441_front.PNG" => {
                    expiry_date => $documents_cr->{proof_of_identity}{documents}{$client_cr->loginid . ".passport.270744441_front.PNG"}{expiry_date},
                    format      => "PNG",
                    id          => 66666,
                    status      => "verified",
                    type        => "passport",
                    },
            },
            is_expired  => 0,
            is_pending  => 1,
            expiry_date => $documents_cr->{proof_of_identity}{documents}{$client_cr->loginid . '.passport.270744441_front.PNG'}{expiry_date},
        },
    };

    cmp_deeply($documents_cr, $document_hash_cr, 'correct structure for client documents');

    my $client        = $client_cr;
    my $document_hash = $document_hash_cr;
    my $module        = Test::MockModule->new('BOM::User::Client');
    $module->mock('authentication_status', sub { 'needs_action' });

    my $documents = $client->documents_uploaded();
    delete $document_hash->{proof_of_address}{is_pending};
    $document_hash->{proof_of_address}{is_rejected} = 1;
    cmp_deeply($documents, $document_hash, 'correct structure for client documents with authentication status as needs_action');

    $module->mock('authentication_status', sub { 'under_review' });

    delete $document_hash->{proof_of_address}{is_rejected};
    $document_hash->{proof_of_address}{is_pending} = 1;

    $documents = $client->documents_uploaded();
    cmp_deeply($documents, $document_hash, 'correct structure for client documents with authentication status as under_review');

    subtest 'Experian validated should not sync expired docs from siblings' => sub {
        my $user = BOM::User->create(
            email          => 'testing@binary.com',
            password       => BOM::User::Password::hashpw('test'),
            email_verified => 1,
        );
        my $client_mock = Test::MockModule->new('BOM::User::Client');
        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
        $status_mock->mock(
            'proveid_requested',
            sub {
                return 1;
            });

        $status_mock->mock(
            'age_verification',
            sub {
                return {reason => 'Experian results are sufficient to mark client as age verified.'};
            });
        $client_mock->mock(
            'is_document_expiry_check_required',
            sub {
                return 1;
            });

        my $client_mf = create_client('MF');
        my $dbh       = $client_mf->db->dbic->dbh;
        $user->add_client($client_mf);

        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client_mf->loginid, 'passport', 'PNG', 'yesterday', 55555, '75bada1e034d13b417083507db47ee4a', 'none', 'front');

        $SQL = 'UPDATE betonmarkets.client_authentication_document SET expiration_date = ?';
        my $sth_doc_update = $dbh->prepare($SQL);
        $sth_doc_update->execute('yesterday');

        my $id = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id);

        my $client_mx = create_client('MX');
        $user->add_client($client_mx);
        my $test = 'BOM::User::Client->documents_expired returns 0 for an Experian validated account';
        is($client_mx->documents_expired(), 0, $test);
        $client_mock->unmock_all;
        $status_mock->unmock_all;
    };

    subtest 'Not validated by Experian should sync from siblings' => sub {
        my $user = BOM::User->create(
            email          => 'testing2@binary.com',
            password       => BOM::User::Password::hashpw('test'),
            email_verified => 1,
        );
        my $client_mock = Test::MockModule->new('BOM::User::Client');
        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
        $status_mock->mock(
            'proveid_requested',
            sub {
                return 1;
            });

        $status_mock->mock(
            'age_verification',
            sub {
                return {reason => 'Onfido upload ok.'};
            });
        $client_mock->mock(
            'is_document_expiry_check_required',
            sub {
                return 1;
            });

        my $client_mf = create_client('MF');
        my $dbh       = $client_mf->db->dbic->dbh;
        $user->add_client($client_mf);

        my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
        my $sth_doc_new = $dbh->prepare($SQL);
        $sth_doc_new->execute($client_mf->loginid, 'passport', 'PNG', 'yesterday', 55555, '75bada1e034d13b417083507db47ee4a', 'none', 'front');

        $SQL = 'UPDATE betonmarkets.client_authentication_document SET expiration_date = ?';
        my $sth_doc_update = $dbh->prepare($SQL);
        $sth_doc_update->execute('yesterday');

        my $id = $sth_doc_new->fetch()->[0];
        $SQL = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
        my $sth_doc_finish = $dbh->prepare($SQL);
        $sth_doc_finish->execute($id);

        my $client_mx = create_client('MX');
        $user->add_client($client_mx);
        my $test = 'BOM::User::Client->documents_expired returns 1 for a Non Experian validated account';
        is($client_mx->documents_expired(), 1, $test);
        $client_mock->unmock_all;
        $status_mock->unmock_all;
    };

    subtest 'for multiple poi documents the latest expiration date is taken into account to flag poi expired' => sub {
        # Set the expiration_date to tomorrow for a specific document_id
        my $dbh            = $client->db->dbic->dbh;
        my $SQL            = 'UPDATE betonmarkets.client_authentication_document SET expiration_date = ? WHERE document_id = ?';
        my $sth_doc_update = $dbh->prepare($SQL);
        $sth_doc_update->execute('tomorrow', '66666');

        # Ensure the remainding documents are expired
        my $SQL2            = 'UPDATE betonmarkets.client_authentication_document SET expiration_date = ? WHERE document_id != ?';
        my $sth_doc_update2 = $dbh->prepare($SQL2);
        $sth_doc_update2->execute('yesterday', '66666');

        $documents = $client->documents_uploaded();
        is($documents->{proof_of_identity}->{is_expired}, 0, 'POI is not expired');
    };

    $module->unmock_all();
};

subtest 'has valid documents' => sub {
    my $mock_client = Test::MockModule->new('BOM::User::Client');

    subtest 'expiry check required' => sub {
        $mock_client->mock(
            'is_document_expiry_check_required',
            sub {
                return 1;
            });

        my $docs = {};
        ok !$client_cr->has_valid_documents($docs), 'Empty documents are not valid documents';

        $docs = {
            'other' => {
                'is_expired' => 1,
                'documents'  => {},
            },
            'proof_of_identity' => {
                'is_expired' => 1,
                'documents'  => {},
            }};

        ok !$client_cr->has_valid_documents($docs), 'Invalid due to expired documents';

        $docs = {
            'other' => {
                'is_expired' => 0,
                'documents'  => {},
            },
            'proof_of_identity' => {
                'is_expired' => 1,
                'documents'  => {},
            }};

        ok !$client_cr->has_valid_documents($docs, 'proof_of_identity'), 'Invalid due to expired POI';
        ok $client_cr->has_valid_documents($docs,  'other'),             'Valid due to non expired Other';

        $docs = {
            'other' => {
                'is_expired' => 1,
                'documents'  => {},
            },
            'proof_of_identity' => {
                'is_expired' => 0,
                'documents'  => {},
            }};

        ok $client_cr->has_valid_documents($docs,  'proof_of_identity'), 'Valid due to non expired POI';
        ok !$client_cr->has_valid_documents($docs, 'other'),             'Invalid due to expired Other';
    };

    subtest 'expiry check not required' => sub {
        $mock_client->mock(
            'is_document_expiry_check_required',
            sub {
                return 0;
            });

        my $docs = {};
        ok !$client_cr->has_valid_documents($docs), 'Empty documents are not valid documents';

        $docs = {
            'other' => {
                'is_expired' => 1,
                'documents'  => {},
            },
            'proof_of_identity' => {
                'is_expired' => 1,
                'documents'  => {},
            }};

        ok $client_cr->has_valid_documents($docs), 'Expire check not required';

        $docs = {
            'other' => {
                'is_expired' => 0,
                'documents'  => {},
            },
            'proof_of_identity' => {
                'is_expired' => 1,
                'documents'  => {},
            }};

        ok $client_cr->has_valid_documents($docs, 'proof_of_identity'), 'Expire check not required';
        ok $client_cr->has_valid_documents($docs, 'other'),             'Expire check not required';

        $docs = {
            'other' => {
                'is_expired' => 1,
                'documents'  => {},
            },
            'proof_of_identity' => {
                'is_expired' => 0,
                'documents'  => {},
            }};

        ok $client_cr->has_valid_documents($docs, 'proof_of_identity'), 'Expire check not required';
        ok $client_cr->has_valid_documents($docs, 'other'),             'Expire check not required';
    };

    $mock_client->unmock_all;
};

subtest 'Empty POI but has a POA' => sub {
    my $docs = {
        'proof_of_address' => {
            'is_expired' => 0,
            'documents'  => {},
        }};

    my $mock_client = Test::MockModule->new('BOM::User::Client');

    $mock_client->mock(
        'documents_uploaded',
        sub {
            return $docs;
        });

    ok !$client_cr->documents_expired, 'The client does not have any POI document therefore cannot be expired';

    $mock_client->unmock_all;
};

subtest 'rejected and uploaded' => sub {

    # Event though the tests above indirectly are proving this.
    # We gotta test that `rejected` or `uploaded` documents should not
    # be taken in consideration by the documents_uploaded sub.

    my $user = BOM::User->create(
        email          => 'fib@binary.com',
        password       => BOM::User::Password::hashpw('1618goldfib'),
        email_verified => 1,
    );

    my $client = create_client('CR');
    $user->add_client($client);

    $client->set_default_account('USD');
    $client->save();

    my $dbh = $client->db->dbic->dbh;
    my $sth_doc_new;
    my $SQL;
    my $id;
    my $id2;

    $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'yesterday', 12345, '75bada1e034d13b417083507db47ee4a', 'none', 'front');
    $id = $sth_doc_new->fetch()->[0];

    $SQL         = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'rejected\'::status_type)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id);

    $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'yesterday', 54321, '75bada1e034d13b417083507db47ee4b', 'none', 'front');
    $id2 = $sth_doc_new->fetch()->[0];

    $SQL         = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'uploaded\'::status_type)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id2);

    my $expected = {
        'proof_of_identity' => {
            'documents' => {
                'CR10001.passport.270744961_front.PNG' => {
                    'id'          => '54321',
                    'type'        => 'passport',
                    'format'      => 'PNG',
                    'expiry_date' => re('\d+'),
                    'status'      => 'uploaded'
                },
                'CR10001.passport.270744941_front.PNG' => {
                    'type'        => 'passport',
                    'id'          => '12345',
                    'format'      => 'PNG',
                    'expiry_date' => re('\d+'),
                    'status'      => 'rejected'
                }
            },
            'is_pending' => 1
        }};

    # Note the documents above are expired but they aren't being taken into consideration
    # for the expiration checkup since they aren't `verified`.

    cmp_deeply $client->documents_uploaded(), $expected, 'We got the expected result from documents uploaded';

    $SQL         = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id);

    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id2);

    # When docs are verified we process the expiration dates
    # Since the client is not age_verification status yet `is_pending` is also set

    $expected = {
        'proof_of_identity' => {
            'is_expired' => 1,
            'documents'  => {
                'CR10001.passport.270744961_front.PNG' => {
                    'format'      => 'PNG',
                    'type'        => 'passport',
                    'status'      => 'verified',
                    'expiry_date' => re('\d+'),
                    'id'          => '54321'
                },
                'CR10001.passport.270744941_front.PNG' => {
                    'format'      => 'PNG',
                    'id'          => '12345',
                    'type'        => 'passport',
                    'expiry_date' => re('\d+'),
                    'status'      => 'verified'
                }
            },
            'expiry_date' => re('\d+'),
            'is_pending'  => 1
        }};

    cmp_deeply $client->documents_uploaded(), $expected, 'We got the expected result from documents uploaded when docs are verified';

    # Now the client is age_verification so `is_pending` will be gone

    $client->status->setnx('age_verification', 'test', 'test');

    $expected = {
        'proof_of_identity' => {
            'is_expired' => 1,
            'documents'  => {
                'CR10001.passport.270744961_front.PNG' => {
                    'format'      => 'PNG',
                    'type'        => 'passport',
                    'status'      => 'verified',
                    'expiry_date' => re('\d+'),
                    'id'          => '54321'
                },
                'CR10001.passport.270744941_front.PNG' => {
                    'format'      => 'PNG',
                    'id'          => '12345',
                    'type'        => 'passport',
                    'expiry_date' => re('\d+'),
                    'status'      => 'verified'
                }
            },
            'expiry_date' => re('\d+'),
        }};

    cmp_deeply $client->documents_uploaded(), $expected, 'We got the expected result from documents uploaded when docs are verified';

    # Now the client uploads fresh document
    # When age_verification is true and we have fresh docs the status should be pending again

    $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'tomorrow', 618900, 'checsum18515', 'none', 'front');
    $id = $sth_doc_new->fetch()->[0];

    $SQL         = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'uploaded\'::status_type)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id);

    $expected = {
        'proof_of_identity' => {
            'is_expired' => 1,
            'is_pending' => 1,
            'documents'  => {
                'CR10001.passport.270744961_front.PNG' => {
                    'format'      => 'PNG',
                    'type'        => 'passport',
                    'status'      => 'verified',
                    'expiry_date' => re('\d+'),
                    'id'          => '54321'
                },
                'CR10001.passport.270744941_front.PNG' => {
                    'format'      => 'PNG',
                    'id'          => '12345',
                    'type'        => 'passport',
                    'expiry_date' => re('\d+'),
                    'status'      => 'verified'
                },
                'CR10001.passport.270745001_front.PNG' => {
                    'expiry_date' => re('\d+'),
                    'format'      => 'PNG',
                    'status'      => 'uploaded',
                    'type'        => 'passport',
                    'id'          => '618900'
                },
            },
            'expiry_date' => re('\d+'),
        }};

    cmp_deeply $client->documents_uploaded(), $expected, 'Fresh documents in needs review make the is_pending flag appear again';

    # The documents are verified

    $SQL         = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id);

    $expected = {
        'proof_of_identity' => {
            'expiry_date' => re('\d+'),
            'is_expired'  => 0,
            'documents'   => {
                'CR10001.passport.270744961_front.PNG' => {
                    'format'      => 'PNG',
                    'type'        => 'passport',
                    'status'      => 'verified',
                    'expiry_date' => re('\d+'),
                    'id'          => '54321'
                },
                'CR10001.passport.270744941_front.PNG' => {
                    'format'      => 'PNG',
                    'id'          => '12345',
                    'type'        => 'passport',
                    'expiry_date' => re('\d+'),
                    'status'      => 'verified'
                },
                'CR10001.passport.270745001_front.PNG' => {
                    'expiry_date' => re('\d+'),
                    'format'      => 'PNG',
                    'status'      => 'verified',
                    'type'        => 'passport',
                    'id'          => '618900'
                },
            },
        }};

    cmp_deeply $client->documents_uploaded(), $expected, 'Fresh verified documents make the account verified';

    # Somebody rejected the doc (from BO)

    $SQL         = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'rejected\'::status_type)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id);

    $expected = {
        'proof_of_identity' => {
            'expiry_date' => re('\d+'),
            'is_expired'  => 1,
            'documents'   => {
                'CR10001.passport.270744961_front.PNG' => {
                    'format'      => 'PNG',
                    'type'        => 'passport',
                    'status'      => 'verified',
                    'expiry_date' => re('\d+'),
                    'id'          => '54321'
                },
                'CR10001.passport.270744941_front.PNG' => {
                    'format'      => 'PNG',
                    'id'          => '12345',
                    'type'        => 'passport',
                    'expiry_date' => re('\d+'),
                    'status'      => 'verified'
                },
                'CR10001.passport.270745001_front.PNG' => {
                    'expiry_date' => re('\d+'),
                    'format'      => 'PNG',
                    'status'      => 'rejected',
                    'type'        => 'passport',
                    'id'          => '618900'
                },
            },
        }};

    cmp_deeply $client->documents_uploaded(), $expected, 'Rejected documents make the account expired';
};

subtest 'rejected an accepted' => sub {

    # This test simulates:
    # 1. Onfido consider (so documents left in the `uploaded` status)
    # 2. Onfido successful resubmission (so new document has `verified` status)

    my $user = BOM::User->create(
        email          => 'fib2@binary.com',
        password       => BOM::User::Password::hashpw('2618goldfib'),
        email_verified => 1,
    );

    my $client = create_client('CR');
    $user->add_client($client);

    $client->set_default_account('USD');
    $client->save();

    my $dbh = $client->db->dbic->dbh;
    my $sth_doc_new;
    my $SQL;
    my $id;
    my $id2;

    $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'tomorrow', 12345, '75bada1e034d13b417083507db47ee4a', 'none', 'front');
    $id = $sth_doc_new->fetch()->[0];

    $SQL         = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'uploaded\'::status_type)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id);

    $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'tomorrow', 54321, '75bada1e034d13b417083507db47ee4b', 'none', 'front');
    $id2 = $sth_doc_new->fetch()->[0];

    $SQL         = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'uploaded\'::status_type)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id2);

    my $expected = {
        'proof_of_identity' => {
            'documents' => {
                'CR10002.passport.270745021_front.PNG' => {
                    'id'          => '12345',
                    'type'        => 'passport',
                    'format'      => 'PNG',
                    'expiry_date' => re('\d+'),
                    'status'      => 'uploaded'
                },
                'CR10002.passport.270745041_front.PNG' => {
                    'type'        => 'passport',
                    'id'          => '54321',
                    'format'      => 'PNG',
                    'expiry_date' => re('\d+'),
                    'status'      => 'uploaded'
                }
            },
            'is_pending' => 1
        }};

    # The documents are left in `uploaded` just like an Onfido consider

    cmp_deeply $client->documents_uploaded(), $expected, 'We got the expected result from documents uploaded';

    # New doc comes in, time valid verification kicks in

    $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'tomorrow', 789, '75bada1e034d13b417083507db47ee43', 'none', 'front');
    $id2 = $sth_doc_new->fetch()->[0];

    $SQL         = 'SELECT * FROM betonmarkets.finish_document_upload(?, \'verified\'::status_type)';
    $sth_doc_new = $dbh->prepare($SQL);
    $sth_doc_new->execute($id2);

    $client->status->setnx('age_verification', 'test', 'test');
    $expected = {
        'proof_of_identity' => {
            'documents' => {
                'CR10002.passport.270745021_front.PNG' => {
                    'id'          => '12345',
                    'type'        => 'passport',
                    'format'      => 'PNG',
                    'expiry_date' => re('\d+'),
                    'status'      => 'uploaded'
                },
                'CR10002.passport.270745041_front.PNG' => {
                    'type'        => 'passport',
                    'id'          => '54321',
                    'format'      => 'PNG',
                    'expiry_date' => re('\d+'),
                    'status'      => 'uploaded'
                },
                'CR10002.passport.270745061_front.PNG' => {
                    'type'        => 'passport',
                    'id'          => '789',
                    'format'      => 'PNG',
                    'expiry_date' => re('\d+'),
                    'status'      => 'verified'
                }
            },
            'is_pending'  => 0,
            'expiry_date' => re('\d+'),
            'is_expired'  => 0,

        }};
    cmp_deeply $client->documents_uploaded(), $expected, 'We got the expected result after Onfido verification';
};

subtest 'Payment Agent has expired documents' => sub {
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    my $mock_lc     = Test::MockModule->new('LandingCompany');
    my $risk;
    my $pa;

    $mock_lc->mock(
        'documents_expiration_check_required',
        sub {
            return 0;
        });

    $mock_client->mock(
        'aml_risk_classification',
        sub {
            return $risk;
        });

    $mock_client->mock(
        'get_payment_agent',
        sub {
            return $pa;
        });

    $risk = 'low';
    $pa   = 1;
    ok $client_cr->is_document_expiry_check_required, 'Expire check required for PA low risk';

    $risk = 'high';
    $pa   = 1;
    ok $client_cr->is_document_expiry_check_required, 'Expire check required for PA high risk';

    $risk = 'low';
    $pa   = 0;
    ok !$client_cr->is_document_expiry_check_required, 'Expire check not required for non PA low risk';

    $risk = 'high';
    $pa   = 0;
    ok $client_cr->is_document_expiry_check_required, 'Expire check required for non PA high risk';

    subtest 'Documents' => sub {
        my $docs;

        $mock_client->mock(
            'documents_uploaded',
            sub {
                return $docs;
            });

        $docs = {
            'proof_of_address' => {
                'is_expired' => 1,
                'documents'  => {}}};

        $risk = 'low';
        $pa   = 0;
        ok $client_cr->has_valid_documents($docs), 'Expire check not required';

        $risk = 'low';
        $pa   = 1;
        ok !$client_cr->has_valid_documents($docs), 'Invalid documents';
    }
};

done_testing();
