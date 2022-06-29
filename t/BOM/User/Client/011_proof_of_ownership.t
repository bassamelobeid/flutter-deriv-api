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
        payment_method            => 'VISA',
        payment_method_identifier => '12345',
    };

    $poo = $client->proof_of_ownership->create($args);

    cmp_deeply $poo,
        {
        creation_time             => re('.+'),
        status                    => 'pending',
        uploaded_time             => undef,
        payment_method_details    => undef,
        client_loginid            => $client->loginid,
        id                        => re('\d+'),
        payment_method            => 'VISA',
        payment_method_identifier => '12345',
        documents                 => [],
        payment_method_details    => {},
        },
        'Expected POO created';

    throws_ok {
        warning_like {
            $client->proof_of_ownership->create($args);
        }
        qr/duplicate key value violates unique constraint/, 'Warns with duplicate violation';
    }
    qr/duplicate key value violates unique constraint/, 'Dies with duplicate violation';
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
                name    => 'THE CAPYBARA',
                expdate => '11/26'
            },
            client_authentication_document_id => $file_id,
        });

    cmp_deeply $poo,
        {
        creation_time             => re('.+'),
        status                    => 'uploaded',
        uploaded_time             => re('.+'),
        payment_method_details    => undef,
        client_loginid            => $client->loginid,
        id                        => re('\d+'),
        payment_method            => 'VISA',
        payment_method_identifier => '12345',
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
        id                        => re('\d+'),
        payment_method            => 'VISA',
        payment_method_identifier => '12345',
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
            creation_time             => re('.+'),
            status                    => 'uploaded',
            uploaded_time             => re('.+'),
            payment_method_details    => undef,
            client_loginid            => $client->loginid,
            id                        => re('\d+'),
            payment_method            => 'VISA',
            payment_method_identifier => '12345',
            documents                 => [$file_id, $file_id2],
            payment_method_details    => {
                name    => 'THE CAPYBARA',
                expdate => '12/26'
            },
        }
        ],
        'Expected full list of POOs retrieved';

    $args = {
        payment_method            => 'Skrill',
        payment_method_identifier => '999',
    };

    $poo = $client->proof_of_ownership->create($args);

    cmp_deeply $client->proof_of_ownership->full_list(),
        [{
            creation_time             => re('.+'),
            status                    => 'uploaded',
            uploaded_time             => re('.+'),
            payment_method_details    => undef,
            client_loginid            => $client->loginid,
            id                        => re('\d+'),
            payment_method            => 'VISA',
            payment_method_identifier => '12345',
            documents                 => [$file_id, $file_id2],
            payment_method_details    => {
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
            creation_time             => re('.+'),
            status                    => 'uploaded',
            uploaded_time             => re('.+'),
            payment_method_details    => undef,
            client_loginid            => $client->loginid,
            id                        => re('\d+'),
            payment_method            => 'VISA',
            payment_method_identifier => '12345',
            documents                 => [$file_id, $file_id2],
            payment_method_details    => {
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
    ok !$client->proof_of_ownership->needs_verification, 'POO does not need verification (pending status)';

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
    ok !$client->proof_of_ownership->needs_verification, 'Does not need POO (pending)';

    is $client->proof_of_ownership->status([]), 'none', 'None status with empty list provided';
    is $client->proof_of_ownership->status([{status => 'pending'}]), 'none', 'None status with pending item provided';
    is $client->proof_of_ownership->status([{status => 'pending'}, {status => 'verified'}]),  'none',     'None, an upload is due';
    is $client->proof_of_ownership->status([{status => 'uploaded'}, {status => 'verified'}]), 'pending',  'pending of review';
    is $client->proof_of_ownership->status([{status => 'pending'}, {status => 'rejected'}]),  'rejected', 'Rejected';
    is $client->proof_of_ownership->status([{status => 'rejected'}, {status => 'rejected'}]), 'rejected', 'all of them are rejected';
    is $client->proof_of_ownership->status([{status => 'verified'}, {status => 'verified'}]), 'verified', 'all of them are verified';

    is $client->proof_of_ownership->needs_verification([]), 0, 'Not needed';
    is $client->proof_of_ownership->needs_verification([{status => 'pending'}]), 1, 'Needed';
    is $client->proof_of_ownership->needs_verification([{status => 'pending'}, {status => 'verified'}]), 1, 'Needed';
    is !$client->proof_of_ownership->needs_verification([{status => 'uploaded'}, {status => 'verified'}]), 1, 'Does not need POO (pending)';
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
        payment_method            => 'Skrill',
        payment_method_identifier => '999',
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
    is $doc->status, 'verified', 'Document is verified too';
    is $client->proof_of_ownership->status, 'pending', 'Pending POO status';
    ok !$client->proof_of_ownership->needs_verification, 'POO does not need verification (pending status)';

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
        id                        => re('\d+'),
        payment_method            => 'Skrill',
        payment_method_identifier => '999',
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
