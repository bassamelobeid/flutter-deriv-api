use strict;
use warnings;

use Test::Deep;
use Test::More;
use Test::MockModule;
use Test::Warnings qw/warnings/;
use Future;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email;
use BOM::User;
use BOM::Event::Process;
use MIME::Base64;
use BOM::Config::Redis;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::Event::Actions::Client;
use Locale::Country qw/code2country/;

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
my $redis_events     = BOM::Config::Redis::redis_events_write();

$s3_mocker->mock(
    'upload',
    sub {
        return Future->done(1);
    });

subtest 'Concurrent calls to onfido_doc_ready_for_upload' => sub {
    $onfido_mocker->mock(
        'download_photo',
        sub {
            return Future->done(
                decode_base64('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVQYV2NgYAAAAAMAAWgmWQ0AAAAASUVORK5CYII='));
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
    $event_mocker->unmock_all;
};

subtest 'Onfido lifetime valid' => sub {
    my $doc_id;
    my $expiration_date;
    my $document;
    my $type;
    my $doc_type;

    $onfido_mocker->mock(
        'download_document',
        sub {
            return Future->done(join '|', 'test', $doc_id);
        });

    $onfido_mocker->mock(
        'download_photo',
        sub {
            return Future->done(join '|', 'test', $doc_id);
        });

    $event_mocker->mock(
        '_get_document_details',
        sub {
            $document = $event_mocker->original('_get_document_details')->(@_);
            return $document;
        });

    my $upload = sub {
        $doc_id          = shift;
        $expiration_date = shift;
        $type            = shift;
        $doc_type        = shift;

        return $action_handler->({
                type           => $type,
                document_id    => $doc_id,
                client_loginid => $test_client->loginid,
                applicant_id   => 'dummy_applicant_id',
                file_type      => 'png',
                document_info  => {
                    type            => $doc_type,
                    expiration_date => $expiration_date,
                }});
    };

    $upload->('abcd', '2019-01-01', 'document', 'passport')->get;
    is $document->{expiration_date}, '2019-01-01', 'Expected expiration date';
    ok !$document->{lifetime_valid}, 'No lifetime valid doc';

    $upload->('qwerty', '', 'document', 'passport')->get;
    ok !$document->{expiration_date}, 'Empty expiration date';
    ok $document->{lifetime_valid}, 'Lifetime valid doc';

    $upload->('cucamonga', '', 'photo', 'selfie')->get;
    ok !$document->{expiration_date}, 'Empty expiration date';
    ok !$document->{lifetime_valid},  'Lifetime valid does not apply to selfie';

    $onfido_mocker->unmock_all;
    $event_mocker->unmock_all;
};

subtest 'Check Onfido Rules' => sub {
    my $action_handler = BOM::Event::Process::get_action_mappings()->{check_onfido_rules};
    my $first_name;
    my $last_name;
    my $result;
    my $current;
    my $check_result;
    my @rejected;

    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    $onfido_mock->mock(
        'get_consider_reasons',
        sub {
            return [@rejected];
        });

    $onfido_mock->mock(
        'get_latest_onfido_check',
        sub {
            return {
                id     => 'TEST',
                status => 'complete',
                result => $check_result,
            };
        });

    $onfido_mock->mock(
        'get_all_onfido_reports',
        sub {
            return {
                DOC => {
                    result     => $result,
                    api_name   => 'document',
                    properties => encode_json_utf8({
                            first_name => $first_name,
                            last_name  => $last_name,
                        }
                    ),
                    breakdown => {},
                }};
        });

    $test_client->first_name('elon');
    $test_client->last_name('musk');
    $test_client->save;

    for (qw/consider clear suspect/) {
        $check_result = $_;

        for (qw/consider clear suspect/) {
            $result = $_;

            for (qw/data_comparison.first_name data_comparison.last_name data_comparison.birthday/) {
                @rejected    = ($_);
                $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
                $last_name   = 'musk';
                $first_name  = 'elon';

                my $mismatch = $test_client->status->poi_name_mismatch;
                ok $action_handler->({
                        loginid  => $test_client->loginid,
                        check_id => 'TEST'
                    })->get, 'Successfull event execution';

                $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
                ok !$test_client->status->poi_name_mismatch, 'POI name mismatch not set';

                if ($mismatch && $result eq 'clear' && $check_result eq 'clear' && $_ ne 'data_comparison.birthday') {
                    ok $test_client->status->age_verification, 'Age verified set';
                } else {
                    ok !$test_client->status->age_verification, 'Age verified not set';
                }

                $test_client->status->clear_age_verification;
                $last_name  = 'mask';
                $first_name = 'elon';

                $test_client = BOM::User::Client->new({loginid => $test_client->loginid});
                ok $action_handler->({
                        loginid  => $test_client->loginid,
                        check_id => 'TEST'
                    })->get, 'Successfull event execution';
                ok $test_client->status->poi_name_mismatch, 'POI name mismatch set';
            }
        }
    }

    $onfido_mock->unmock_all;
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

subtest 'Unsupported country email' => sub {
    my $tests = [{
            place_of_birth => undef,
            residence      => 'aq',
            strings        => [
                '<p>Place of birth is not set and residence is not supported by Onfido. Please verify the age of the client manually.</p>',
                '<li><b>place of birth:</b> not set</li>',
                '<li><b>residence:</b> ' . code2country('aq') . '</li>'
            ],
        },
        {
            place_of_birth => 'aq',
            residence      => 'aq',
            strings        => [
                '<p>Place of birth is not supported by Onfido. Please verify the age of the client manually.</p>',
                '<li><b>place of birth:</b> ' . code2country('aq') . '</li>',
                '<li><b>residence:</b> ' . code2country('aq') . '</li>'
            ],
        }];

    for my $test ($tests->@*) {
        my ($place_of_birth, $residence, $strings) = @{$test}{qw/place_of_birth residence strings/};

        $test_client->place_of_birth($place_of_birth);
        $test_client->residence($residence);
        $test_client->save;

        $redis_events->del('ONFIDO::UNSUPPORTED::COUNTRY::EMAIL::PER::USER::' . $test_client->binary_user_id);

        mailbox_clear();

        ok BOM::Event::Actions::Client::_send_email_onfido_unsupported_country_cs($test_client)->get, 'email sent';

        my $msg = mailbox_search(subject => qr/Manual age verification needed for/);

        ok $msg, 'Email found';

        for my $string ($strings->@*) {
            ok index($msg->{body}, $string) > -1, 'Expected content found';
        }
    }
};
$s3_mocker->unmock_all;

done_testing();
