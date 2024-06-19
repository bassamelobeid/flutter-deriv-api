use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

isa_ok $client->proof_of_ownership, 'BOM::User::Client::ProofOfOwnership', 'Expected reference to POO';

my ($poo, $args);
my ($file_id, $file_id2, $file_id3);

subtest 'Create POO' => sub {
    $args = {
        payment_service_provider => 'VISA',
        trace_id                 => 1,
    };

    $poo = $client->proof_of_ownership->create($args);

    cmp_deeply $poo,
        {
        creation_time          => re('.+'),
        status                 => 'pending',
        trace_id               => 1,
        comment                => undef,
        uploaded_time          => undef,
        payment_method_details => undef,
        client_loginid         => $client->loginid,
        id                     => re('\d+'),
        payment_method         => 'VISA',
        documents              => [],
        payment_method_details => {},
        },
        'Expected POO created';

    # throws_ok {
    #     warning_like {
    #         $client->proof_of_ownership->create($args);
    #     }
    #     qr/duplicate key value violates unique constraint/, 'Warns with duplicate violation';
    # }
    # qr/duplicate key value violates unique constraint/, 'Dies with duplicate violation';
};

subtest 'List of POO' => sub {
    cmp_deeply $client->proof_of_ownership->list(),
        [{
            $poo->%*,
            documents              => [],
            payment_method_details => {},
        }
        ],
        'Expected list of POOs retrieved';

    cmp_deeply $client->proof_of_ownership->list({id => -1}), [], 'Expected list of POOs retrieved (empty)';

    cmp_deeply $client->proof_of_ownership->list({
            id => $poo->{id},
        }
        ),
        [{
            $poo->%*,
            documents              => [],
            payment_method_details => {},
        }
        ],
        'Expected list of POOs retrieved';

    cmp_deeply $client->proof_of_ownership->list({
            id     => undef,
            status => 'uploaded'
        }
        ),
        [], 'Expected list of POOs retrieved (empty)';

    cmp_deeply $client->proof_of_ownership->list({
            id     => undef,
            status => 'pending'
        }
        ),
        [{
            $poo->%*,
            documents              => [],
            payment_method_details => {},
        }
        ],
        'Expected list of POOs retrieved';

    cmp_deeply $client->proof_of_ownership->list({
            id     => $poo->{id},
            status => 'pending'
        }
        ),
        [{
            $poo->%*,
            documents              => [],
            payment_method_details => {},
        }
        ],
        'Expected list of POOs retrieved (both args)';
};

subtest 'Fulfilling the POO' => sub {
    throws_ok {
        $client->proof_of_ownership->fulfill({
            id => -1,
        });
    }
    qr/Cannot fulfill proof of ownership/, 'Expected exception thrown';

    throws_ok {
        $client->proof_of_ownership->fulfill({id => $poo->{id}});
    }
    qr/Cannot fulfill proof of ownership/, 'Expected exception thrown';

    throws_ok {
        $client->proof_of_ownership->fulfill({
            id                     => $poo->{id},
            payment_method_details => {},
        });
    }
    qr/Cannot fulfill proof of ownership/, 'Expected exception thrown';

    # upload a proof of ownership doc
    $file_id = upload($client);

    ok $file_id, 'There is a document uploaded';

    $poo = $client->proof_of_ownership->fulfill({
            id                     => $poo->{id},
            payment_method_details => {
                name               => 'THE CAPYBARA',
                expdate            => '11/26',
                payment_identifier => 'test',
            },
            client_authentication_document_id => $file_id,
        });

    cmp_deeply $poo,
        {
        creation_time             => re('.+'),
        status                    => 'uploaded',
        uploaded_time             => re('.+'),
        payment_method_details    => undef,
        payment_method_identifier => 'DEPRECATED',
        client_loginid            => $client->loginid,
        id                        => re('\d+'),
        payment_method            => 'VISA',
        documents                 => [$file_id],
        payment_method_details    => {
            name    => 'THE CAPYBARA',
            expdate => '11/26'
        },
        },
        'Expected updated POO';

    # can attach more documents

    $file_id2 = upload(
        $client,
        {
            document_id => 555,
            checksum    => 'checkthat'
        });

    ok $file_id2, 'There is a document uploaded';

    $poo = $client->proof_of_ownership->fulfill({
            id                     => $poo->{id},
            payment_method_details => {
                name    => 'THE CAPYBARA',
                expdate => '12/26'
            },
            client_authentication_document_id => $file_id2,
        });

    cmp_deeply $poo,
        {
        creation_time             => re('.+'),
        status                    => 'uploaded',
        uploaded_time             => re('.+'),
        payment_method_details    => undef,
        client_loginid            => $client->loginid,
        payment_method_identifier => 'DEPRECATED',
        id                        => re('\d+'),
        payment_method            => 'VISA',
        documents                 => [$file_id, $file_id2],
        payment_method_details    => {
            name    => 'THE CAPYBARA',
            expdate => '12/26'
        },
        },
        'Expected updated POO';
};

subtest 'Full List' => sub {
    cmp_deeply $client->proof_of_ownership->full_list(),
        [{
            creation_time          => re('.+'),
            status                 => 'uploaded',
            uploaded_time          => re('.+'),
            payment_method_details => undef,
            trace_id               => 1,
            comment                => undef,
            client_loginid         => $client->loginid,
            id                     => re('\d+'),
            payment_method         => 'VISA',
            documents              => [$file_id, $file_id2],
            payment_method_details => {
                name    => 'THE CAPYBARA',
                expdate => '12/26'
            },
        }
        ],
        'Expected full list of POOs retrieved';

    $args = {
        payment_service_provider => 'Skrill',
        trace_id                 => 2,
    };

    $poo = $client->proof_of_ownership->create($args);

    cmp_deeply $client->proof_of_ownership->full_list(),
        [{
            creation_time          => re('.+'),
            status                 => 'uploaded',
            uploaded_time          => re('.+'),
            payment_method_details => undef,
            trace_id               => 1,
            comment                => undef,
            client_loginid         => $client->loginid,
            id                     => re('\d+'),
            payment_method         => 'VISA',
            documents              => [$file_id, $file_id2],
            payment_method_details => {
                name    => 'THE CAPYBARA',
                expdate => '12/26'
            },
        }
        ],
        'Expected full list of POOs retrieved (cached)';

    # flush the cache
    $client->proof_of_ownership->_clear_full_list();
    cmp_deeply $client->proof_of_ownership->full_list(),
        [{
            creation_time          => re('.+'),
            status                 => 'uploaded',
            uploaded_time          => re('.+'),
            payment_method_details => undef,
            trace_id               => 1,
            comment                => undef,
            client_loginid         => $client->loginid,
            id                     => re('\d+'),
            payment_method         => 'VISA',
            documents              => [$file_id, $file_id2],
            payment_method_details => {
                name    => 'THE CAPYBARA',
                expdate => '12/26'
            },
        },
        $poo
        ],
        'Expected full list of POOs retrieved (after cache flush)';
};

subtest 'status and needs_verification' => sub {
    is $client->proof_of_ownership->status, 'pending', 'Pending POO status';
    ok $client->proof_of_ownership->needs_verification, 'POO does need verification (pending status)';

    $file_id3 = upload(
        $client,
        {
            document_id => 890,
            checksum    => 'checkitup'
        });

    ok $file_id3, 'There is a document uploaded';

    # flush the cache
    $client->proof_of_ownership->_clear_full_list();

    $poo = $client->proof_of_ownership->fulfill({
            id                     => $poo->{id},
            payment_method_details => {
                name    => 'EL CARPINCHO',
                expdate => '12/28'
            },
            client_authentication_document_id => $file_id3,
        });

    is $client->proof_of_ownership->status, 'pending', 'All the POOs have been uploaded';
    ok $client->proof_of_ownership->needs_verification, 'Needs verification (pending status)';

    is $client->proof_of_ownership->status([]),                                               'none',     'None status with empty list provided';
    is $client->proof_of_ownership->status([{status => 'pending'}]),                          'none',     'None status with pending item provided';
    is $client->proof_of_ownership->status([{status => 'pending'}, {status => 'verified'}]),  'none',     'None, an upload is due';
    is $client->proof_of_ownership->status([{status => 'uploaded'}, {status => 'verified'}]), 'pending',  'pending of review';
    is $client->proof_of_ownership->status([{status => 'pending'}, {status => 'rejected'}]),  'rejected', 'Rejected';
    is $client->proof_of_ownership->status([{status => 'rejected'}, {status => 'rejected'}]), 'rejected', 'all of them are rejected';
    is $client->proof_of_ownership->status([{status => 'verified'}, {status => 'verified'}]), 'verified', 'all of them are verified';

    is $client->proof_of_ownership->needs_verification([]),                                               0, 'Not needed';
    is $client->proof_of_ownership->needs_verification([{status => 'pending'}]),                          1, 'Needed';
    is $client->proof_of_ownership->needs_verification([{status => 'pending'}, {status => 'verified'}]),  1, 'Needed';
    is $client->proof_of_ownership->needs_verification([{status => 'uploaded'}, {status => 'verified'}]), 1, 'Needs verification (pending)';
    is $client->proof_of_ownership->needs_verification([{status => 'pending'}, {status => 'rejected'}]),  1, 'Needed';
    is $client->proof_of_ownership->needs_verification([{status => 'rejected'}, {status => 'rejected'}]), 1, 'Needed';
    is $client->proof_of_ownership->needs_verification([{status => 'verified'}, {status => 'verified'}]), 0, 'Verified';
};

subtest 'verify and reject' => sub {
    $poo = $client->proof_of_ownership->verify({
        id => $poo->{id},
    });

    cmp_deeply $poo,
        {
        creation_time             => re('.+'),
        status                    => 'verified',
        uploaded_time             => re('.+'),
        payment_method_details    => undef,
        client_loginid            => $client->loginid,
        id                        => re('\d+'),
        payment_method_identifier => 'DEPRECATED',
        payment_method            => 'Skrill',
        documents                 => [$file_id3],
        payment_method_details    => {
            name    => 'EL CARPINCHO',
            expdate => '12/28'
        },
        },
        'Expected updated POO';

    my ($doc) = $client->find_client_authentication_document(query => [id => $file_id3]);

    # flush the cache
    $client->proof_of_ownership->_clear_full_list();
    is $doc->status,                        'verified', 'Document is verified too';
    is $client->proof_of_ownership->status, 'pending',  'Pending POO status';
    ok $client->proof_of_ownership->needs_verification, 'POO does need verification (pending status)';

    my $file_id4 = upload(
        $client,
        {
            document_id => 999,
            checksum    => 'heyheyhey'
        });

    ok $file_id4, 'There is a document uploaded';

    # flush the cache
    $client->proof_of_ownership->_clear_full_list();

    $poo = $client->proof_of_ownership->fulfill({
            id                     => $poo->{id},
            payment_method_details => {
                name    => 'EL CARPINCHO',
                expdate => '12/28'
            },
            client_authentication_document_id => $file_id4,
        });
    $poo = $client->proof_of_ownership->reject({
        id => $poo->{id},
    });

    cmp_deeply $poo,
        {
        creation_time             => re('.+'),
        status                    => 'rejected',
        uploaded_time             => re('.+'),
        payment_method_details    => undef,
        client_loginid            => $client->loginid,
        payment_method_identifier => 'DEPRECATED',
        id                        => re('\d+'),
        payment_method            => 'Skrill',
        documents                 => [$file_id3, $file_id4],
        payment_method_details    => {
            name    => 'EL CARPINCHO',
            expdate => '12/28'
        },
        },
        'Expected updated POO';

    ($doc) = $client->find_client_authentication_document(query => [id => $file_id4]);
    is $doc->status, 'rejected', 'new document got rejected status';

    ($doc) = $client->find_client_authentication_document(query => [id => $file_id3]);
    is $doc->status, 'verified', 'old document status still verified (must be manually amended by staff if needed)';

    # flush the cache
    $client->proof_of_ownership->_clear_full_list();
    my $list = $client->proof_of_ownership->full_list();

    is $client->proof_of_ownership->status, 'rejected', 'Rejected POO status';
    ok $client->proof_of_ownership->needs_verification, 'POO needs verification';

    $client->proof_of_ownership->reject($_) for $list->@*;
    $client->proof_of_ownership->_clear_full_list();

    is $client->proof_of_ownership->status, 'rejected', 'rejected POO status';
    ok $client->proof_of_ownership->needs_verification, 'POO needs verification';

    $client->proof_of_ownership->verify($_) for $list->@*;
    $client->proof_of_ownership->_clear_full_list();

    is $client->proof_of_ownership->status, 'verified', 'verified POO status';
    ok !$client->proof_of_ownership->needs_verification, 'POO does not verification';
};

subtest 'resubmit and delete' => sub {

    $args = {
        payment_service_provider => 'VISA',
        trace_id                 => 2,
        comment                  => 'test'
    };

    $poo = $client->proof_of_ownership->create($args);

    $poo = $client->proof_of_ownership->verify({
        id => $poo->{id},
    });

    $client->proof_of_ownership->_clear_full_list();

    cmp_deeply $poo,
        {
        'payment_method_details'    => {},
        'documents'                 => [],
        'id'                        => '3',
        'payment_method'            => 'VISA',
        'creation_time'             => re('.+'),
        'status'                    => 'verified',
        'payment_method_identifier' => 'DEPRECATED',
        'client_loginid'            => 'CR10000',
        'uploaded_time'             => undef
        },
        'Expected updated POO';

    $poo = $client->proof_of_ownership->reject({
        id => $poo->{id},
    });

    is $client->proof_of_ownership->status, 'rejected', 'Rejected POO status';

    $client->proof_of_ownership->resubmit({
        id => $poo->{id},
    });

    $client->proof_of_ownership->_clear_full_list();

    is $client->proof_of_ownership->status, 'pending', 'Uploaded POO status';

    $client->proof_of_ownership->delete({
        id => $poo->{id},
    });

    $client->proof_of_ownership->_clear_full_list();

    my $poo_list = $client->proof_of_ownership->list({
        id => $poo->{id},
    });

    ok !grep { $_->{id} == $poo->{id} } @$poo_list;

};

subtest 'update comment' => sub {
    $args = {
        payment_service_provider => 'VISA',
        trace_id                 => 3
    };

    $poo = $client->proof_of_ownership->create($args);

    $poo = $client->proof_of_ownership->verify({
        id => $poo->{id},
    });

    $client->proof_of_ownership->_clear_full_list();

    cmp_deeply $poo,
        {
        'payment_method_details'    => {},
        'documents'                 => [],
        'id'                        => '4',
        'payment_method'            => 'VISA',
        'creation_time'             => re('.+'),
        'status'                    => 'verified',
        'payment_method_identifier' => 'DEPRECATED',
        'client_loginid'            => 'CR10000',
        'uploaded_time'             => undef
        },
        'Expected updated POO';

    my $comments_to_update = [{
            "id"      => '4',
            "comment" => "updated comment"
        }];

    $client->proof_of_ownership->update_comments({poo_comments => $comments_to_update});

    my $full_list = $client->proof_of_ownership->full_list();

    cmp_deeply $full_list,
        [{
            'uploaded_time'          => re('.+'),
            'payment_method_details' => {
                'expdate' => '12/26',
                'name'    => 'THE CAPYBARA'
            },
            'client_loginid' => 'CR10000',
            'trace_id'       => '1',
            'comment'        => undef,
            'status'         => 'verified',
            'creation_time'  => re('.+'),
            'payment_method' => 'VISA',
            'id'             => '1',
            'documents'      => ['270744401', '270744421']
        },
        {
            'creation_time'          => re('.+'),
            'payment_method'         => 'Skrill',
            'status'                 => 'verified',
            'documents'              => ['270744441', '270744461'],
            'id'                     => '2',
            'payment_method_details' => {
                'expdate' => '12/28',
                'name'    => 'EL CARPINCHO'
            },
            'uploaded_time'  => re('.+'),
            'client_loginid' => 'CR10000',
            'trace_id'       => '2',
            'comment'        => undef
        },
        {
            'trace_id'               => '3',
            'comment'                => 'updated comment',
            'uploaded_time'          => undef,
            'payment_method_details' => {},
            'client_loginid'         => 'CR10000',
            'id'                     => '4',
            'documents'              => [],
            'status'                 => 'verified',
            'creation_time'          => re('.+'),
            'payment_method'         => 'VISA'
        }
        ],
        'Expected full list of POOs retrieved with updated comments';

};

sub upload {
    my ($client, $doc) = @_;

    my $file = $client->start_document_upload({
        document_type   => 'proof_of_ownership',
        document_format => 'png',
        checksum        => 'checkthis',
        document_id     => 555,
        $doc ? $doc->%* : (),
    });

    return $client->finish_document_upload($file->{file_id});
}

done_testing();
