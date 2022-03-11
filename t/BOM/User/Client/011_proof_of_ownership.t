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

my ($poo,     $args);
my ($file_id, $file_id2);

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

subtest 'status and needs needs_verification' => sub {
    is $client->proof_of_ownership->status, 'pending', 'Pending POO status';
    ok $client->proof_of_ownership->needs_verification, 'POO needs verification';

    my $file_id3 = upload(
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

    is $client->proof_of_ownership->status, 'none', 'All the POOs have been uploaded';
    ok !$client->proof_of_ownership->needs_verification, 'No need for POO verification';

    is $client->proof_of_ownership->status([]), 'none', 'None status with empty list provided';
    is $client->proof_of_ownership->status([{status => 'pending'}]), 'pending', 'Pending status with pending item provided';
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
