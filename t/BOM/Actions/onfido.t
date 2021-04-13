use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Warnings qw/warnings/;
use Future;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;
use BOM::Event::Process;
use MIME::Base64;
use BOM::Config::Redis;
use BOM::Event::Actions::Client;

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test1@bin.com',
});

my $email = $test_client->email;
my $user  = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);

$user->add_client($test_client);
my $action_handler   = BOM::Event::Process::get_action_mappings()->{onfido_doc_ready_for_upload};
my $onfido_mocker    = Test::MockModule->new('WebService::Async::Onfido');
my $s3_mocker        = Test::MockModule->new('BOM::Platform::S3Client');
my $event_mocker     = Test::MockModule->new('BOM::Event::Actions::Client');
my $redis_replicated = BOM::Config::Redis::redis_replicated_write();

subtest 'Concurrent calls to onfido_doc_ready_for_upload' => sub {
    $onfido_mocker->mock(
        'download_photo',
        sub {
            return Future->done(
                decode_base64('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVQYV2NgYAAAAAMAAWgmWQ0AAAAASUVORK5CYII='));
        });

    $s3_mocker->mock(
        'upload',
        sub {
            return Future->done(1);
        });

    my $exceptions = 0;
    $event_mocker->mock(
        'exception_logged',
        sub {
            $exceptions++;
        });

    my $upload_generator = sub {
        return $action_handler->({
            type           => 'photo',
            document_id    => 'dummy_doc_id',
            client_loginid => $test_client->loginid,
            applicant_id   => 'dummy_applicant_id',
            file_type      => 'png',
        });
    };

    # Run it ten times to stress it a bit
    my $f = Future->wait_all(map { $upload_generator->() } (1 .. 10));
    $f->on_ready(
        sub {
            is $exceptions, 0, 'Exception counter is ZERO';
            my $keys = $redis_replicated->keys('*ONFIDO_UPLOAD_BAG*');
            is scalar @$keys, 0, 'Lock released';
        });

    my @warnings = warnings {
        $f->get;
    };

    is scalar @warnings, 0, 'Warning counter is ZERO';
    print @warnings if scalar @warnings;

    $onfido_mocker->unmock_all;
    $s3_mocker->unmock_all;
    $event_mocker->unmock_all;
};

subtest 'Final status' => sub {
    my $cases = [{
            result => undef,
            status => 'uploaded'
        },
        {
            result => 'test',
            status => 'uploaded',
        },
        {
            result => 'clear',
            status => 'verified',
        },
        {
            result => 'consider',
            status => 'rejected',
        },
        {
            result => 'suspect',
            status => 'rejected',
        }];

    for my $case ($cases->@*) {
        is BOM::Event::Actions::Client::_get_document_final_status($case->{result}), $case->{status},
            "The exepcted status for " . ($case->{result} // 'undef');
    }
};

done_testing();
