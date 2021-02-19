use strict;
use warnings;
use Test::More;
use BOM::User::Client;
use BOM::User;
use Test::Exception;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $file;
my $id;

subtest 'Start Document Upload' => sub {

    # Bare minimum params to avoid a constraint violation

    lives_ok {
        $file = $test_client->start_document_upload({
                document_type   => 'passport',
                document_format => 'png',
                document_id     => '1618',
                checksum        => 'checkthis',
                page_type       => 'front',
            })
    }
    'No exception seen';

    cmp_deeply $file,
        {
        file_name => re('.+'),
        file_id   => re('\d+'),
        },
        'Successfully started the upload';
};

subtest 'Finish Document Upload' => sub {
    lives_ok {
        $id = $test_client->finish_document_upload($file->{file_id})
    }
    'No exception seen';

    is $id, $file->{file_id}, 'Expected result for a finished upload';
};

done_testing();
