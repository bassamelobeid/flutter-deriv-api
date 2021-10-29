use strict;
use warnings;

use Test::Deep;
use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::Warnings qw/warnings/;
use Future;
use Future::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email;
use BOM::User;
use BOM::Event::Process;
use MIME::Base64;
use BOM::Config::Redis;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::Event::Actions::Client;
use Locale::Country qw/code2country/;
use Ryu::Source;
use HTTP::Response;
use WebService::Async::Onfido::Applicant;

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
            selected_country => undef,
            place_of_birth   => undef,
            residence        => 'aq',
            strings          => [
                '<p>No country specified by user, place of birth is not set and residence is not supported by Onfido. Please verify the age of the client manually.</p>',
                '<li><b>specified country:</b> not set</li>',
                '<li><b>place of birth:</b> not set</li>',
                '<li><b>residence:</b> ' . code2country('aq') . '</li>'
            ],
        },
        {
            selected_country => undef,
            place_of_birth   => 'aq',
            residence        => 'aq',
            strings          => [
                '<p>Place of birth is not supported by Onfido. Please verify the age of the client manually.</p>',
                '<li><b>specified country:</b> not set</li>',
                '<li><b>place of birth:</b> ' . code2country('aq') . '</li>',
                '<li><b>residence:</b> ' . code2country('aq') . '</li>'
            ],
        },
        {
            selected_country => 'aq',
            place_of_birth   => 'aq',
            residence        => 'aq',
            strings          => [
                '<p>Place of birth is not supported by Onfido. Please verify the age of the client manually.</p>',
                '<li><b>specified country:</b> ' . code2country('aq') . '</li>',
                '<li><b>place of birth:</b> ' . code2country('aq') . '</li>',
                '<li><b>residence:</b> ' . code2country('aq') . '</li>'
            ]
        },
        {
            selected_country => 'aq',
            place_of_birth   => 'ir',
            residence        => 'aq',
            strings          => [
                '<p>The specified country by user `aq` is not supported by Onfido. Please verify the age of the client manually.',
                '<li><b>specified country:</b> ' . code2country('aq') . '</li>',
                '<li><b>place of birth:</b> ' . code2country('ir') . '</li>',
                '<li><b>residence:</b> ' . code2country('aq') . '</li>'
            ]}];

    for my $test ($tests->@*) {
        my ($selected_country, $place_of_birth, $residence, $strings) = @{$test}{qw/selected_country place_of_birth residence strings/};

        $test_client->place_of_birth($place_of_birth);
        $test_client->residence($residence);
        $test_client->save;

        $redis_events->del('ONFIDO::UNSUPPORTED::COUNTRY::EMAIL::PER::USER::' . $test_client->binary_user_id);

        mailbox_clear();

        ok BOM::Event::Actions::Client::_send_email_onfido_unsupported_country_cs($test_client, $selected_country)->get, 'email sent';

        my $msg = mailbox_search(subject => qr/Manual age verification needed for/);

        ok $msg, 'Email found';

        for my $string ($strings->@*) {
            ok index($msg->{body}, $string) > -1, 'Expected content found';
        }
    }
};

subtest 'Forged documents email' => sub {
    my $tests = [{
            residence => 'br',
            strings   => [
                '<p>Client uploaded new POI and account is locked due to forged SOP, please help to check and unlock if the document is legit, and to follow forged SOP if the document is forged again.</p>',
                '<li><b>loginid:</b> ' . $test_client->loginid . '</li>',
                '<li><b>residence:</b> ' . code2country('br') . '</li>'
            ],
            email     => 1,
            clear_ttl => 0,
        },
        {
            residence => 'gb',
            strings   => [
                '<p>Client uploaded new POI and account is locked due to forged SOP, please help to check and unlock if the document is legit, and to follow forged SOP if the document is forged again.</p>',
                '<li><b>loginid:</b> ' . $test_client->loginid . '</li>',
                '<li><b>residence:</b> ' . code2country('gb') . '</li>'
            ],
            email     => 0,
            clear_ttl => 0,
        },
        {
            residence => 'gb',
            strings   => [
                '<p>Client uploaded new POI and account is locked due to forged SOP, please help to check and unlock if the document is legit, and to follow forged SOP if the document is forged again.</p>',
                '<li><b>loginid:</b> ' . $test_client->loginid . '</li>',
                '<li><b>residence:</b> ' . code2country('gb') . '</li>'
            ],
            email     => 1,
            clear_ttl => 1,
        },
    ];

    for my $test ($tests->@*) {
        my ($residence, $strings, $clear_ttl, $email) = @{$test}{qw/residence strings clear_ttl email/};

        my $country = code2country($residence);
        $test_client->residence($residence);
        $test_client->save;

        mailbox_clear();

        if ($clear_ttl) {
            $redis_events->del('FORGED::EMAIL::LOCK::' . $test_client->loginid);
        }

        is BOM::Event::Actions::Client::_notify_onfido_on_forged_document($test_client)->get, undef, 'email sent';

        my $msg = mailbox_search(subject => qr/New POI uploaded for acc with forged lock - $country/);

        if ($email) {
            ok $msg, 'Email found';

            for my $string ($strings->@*) {
                ok index($msg->{body}, $string) > -1, 'Expected content found';
            }

            ok $redis_events->ttl('FORGED::EMAIL::LOCK::' . $test_client->loginid) > 0, 'TTL set';
        } else {
            ok !$msg, 'Email not send';
        }
    }
};

subtest 'Applicant Check' => sub {
    my $ryu_mock = Test::MockModule->new('Ryu::Source');

    $onfido_mocker->mock(
        'photo_list',
        sub {
            return Ryu::Source->new;
        });

    $ryu_mock->mock(
        'as_list',
        sub {
            return Future->done();
        });

    $event_mocker->mock(
        '_update_onfido_check_count',
        sub {
            return Future->done();
        });

    $event_mocker->mock(
        '_update_onfido_user_check_count',
        sub {
            return Future->done();
        });

    $log->clear();
    BOM::Event::Actions::Client::_check_applicant(undef, BOM::Event::Actions::Client::_onfido(),
        'mocked-applicant-id', undef, $test_client->loginid, undef, undef, $test_client)->get;
    $log->contains_ok(qr/applicant mocked-applicant-id does not have live photos/, 'expected log found');

    my %request;
    $onfido_mocker->mock(
        'applicant_check',
        sub {
            (undef, %request) = @_;
            my $res = HTTP::Response->new(422);
            $res->content('{"error":"awful result"}');
            return Future->fail('something awful', undef, $res);
        });

    $ryu_mock->mock(
        'as_list',
        sub {
            return Future->done(1, 2, 3);
        });

    $log->clear();
    BOM::Event::Actions::Client::_check_applicant(undef, BOM::Event::Actions::Client::_onfido(),
        'mocked-applicant-id', 'CR', $test_client->loginid, 'BRA', undef, $test_client)->get;
    $log->contains_ok(qr/An error occurred while processing Onfido verification for/, 'expected log found');

    cmp_deeply \%request,
        {
        suppress_form_emails => 1,
        type                 => 'express',
        tags                 => ['automated', 'CR', $test_client->loginid, 'BRA', 'brand:deriv'],
        async                => 1,
        applicant_id         => 'mocked-applicant-id',
        reports              => [{
                name => 'document',
            },
            {
                name    => 'facial_similarity',
                variant => 'standard'
            }]
        },
        'Expected request for applicant check';

    $event_mocker->unmock('_update_onfido_check_count');
    $event_mocker->unmock('_update_onfido_user_check_count');
    $onfido_mocker->unmock('applicant_check');
    $onfido_mocker->unmock('photo_list');
    $ryu_mock->unmock_all;
};

subtest 'Upload document' => sub {
    my %request;
    $event_mocker->mock(
        '_get_applicant_and_file',
        sub {
            return Future->done(
                WebService::Async::Onfido::Applicant->new(
                    id => 'appl',
                ),
                'big blob'
            );
        });
    $onfido_mocker->mock(
        'live_photo_upload',
        sub {
            (undef, %request) = @_;
            my $res = HTTP::Response->new(422);
            $res->content('{"error":"awful result"}');
            return Future->fail('test1', 'test2', $res);
        });
    $onfido_mocker->mock(
        'document_upload',
        sub {
            (undef, %request) = @_;
            my $res = HTTP::Response->new(422);
            $res->content('{"error":"awful result"}');
            return Future->fail('test1', 'test2', $res);
        });

    my $args = {
        onfido         => BOM::Event::Actions::Client::_onfido(),
        client         => $test_client,
        document_entry => {file_name => '124112412.passport.front.png'},
        file_data      => {

        },
    };

    $log->clear();
    BOM::Event::Actions::Client::_upload_documents($args->%*)->get;

    $log->contains_ok(qr/An error occurred while uploading document to Onfido for/, 'expected log found');
    cmp_deeply \%request,
        {
        data            => 'big blob',
        type            => 'passport',
        filename        => '124112412.passport.front.png',
        side            => 'front',
        issuing_country => 'IRN',
        applicant_id    => 'appl',
        },
        'Expected request for document';

    $args = {
        onfido         => BOM::Event::Actions::Client::_onfido(),
        client         => $test_client,
        document_entry => {file_name => '124112412.selfie_with_id.photo.png'},
        file_data      => {

        },
    };
    $log->clear();
    BOM::Event::Actions::Client::_upload_documents($args->%*)->get;

    $log->contains_ok(qr/An error occurred while uploading document to Onfido for/, 'expected log found');
    cmp_deeply \%request,
        {
        data         => 'big blob',
        filename     => '124112412.selfie_with_id.photo.png',
        applicant_id => 'appl',
        },
        'Expected request for selfie';

    $event_mocker->unmock('_get_applicant_and_file');
    $onfido_mocker->unmock('document_upload');
    $onfido_mocker->unmock('live_photo_upload');
};

subtest '_get_onfido_applicant' => sub {
    my $onfido     = BOM::Event::Actions::Client::_onfido();
    my $event_mock = Test::MockModule->new('BOM::Event::Actions::Client');
    my ($traced_subs);
    $event_mock->mock(
        '_send_email_onfido_unsupported_country_cs',
        sub {
            $traced_subs->{_send_email_onfido_unsupported_country_cs} = 1;
            return Future->done(1);
        });
    my $config_mock = Test::MockModule->new('BOM::Config::Onfido');
    my ($is_country_supported);
    $config_mock->mock(
        'is_country_supported',
        sub {
            return $is_country_supported;
        });
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my ($stats_inc, $stats_timing);
    $dog_mock->mock(
        'stats_inc',
        sub {
            $stats_inc = {@_, $stats_inc ? $stats_inc->%* : ()};
            return;
        });
    $dog_mock->mock(
        'stats_timing',
        sub {
            $stats_timing = {@_, $stats_timing ? $stats_timing->%* : ()};
            return;
        });
    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my ($applicant_id, $applicant_exists, $store_applicant);
    $onfido_mock->mock(
        'get_user_onfido_applicant',
        sub {
            return undef unless $applicant_exists;

            return {
                id => $applicant_id,
            };
        });
    $onfido_mock->mock(
        'store_onfido_applicant',
        sub {
            $store_applicant = [@_];
            return;
        });
    my $onfido_async_mock = Test::MockModule->new(ref($onfido));
    my ($onfido_exception, $onfido_http_exception);
    $onfido_async_mock->mock(
        'applicant_get',
        sub {
            return Future->done(
                WebService::Async::Onfido::Applicant->new(
                    id => $applicant_id,
                ));
        });
    $onfido_async_mock->mock(
        'applicant_create',
        sub {
            if ($onfido_http_exception) {
                my $res = HTTP::Response->new(422);
                $res->content(eval { encode_json_utf8($onfido_http_exception) });

                Future::Exception->throw('some exception', 'http', $res);
            }
            die $onfido_exception if $onfido_exception;
            return Future->done(undef) unless $applicant_id;
            return Future->done(
                WebService::Async::Onfido::Applicant->new(
                    id => $applicant_id,
                ));
        });

    my $tests = [{
            title  => 'Unsupported POB country not uploaded by staff',
            client => {
                place_of_birth => 'gb',
                residence      => 'gb',
                email          => 'test1@binary.com',
                broker_code    => 'MX',
            },
            uploaded_manually_by_staff => 0,
            is_country_supported       => 0,
            logs                       => [qr/\bDocument not uploaded to Onfido as client is from list of countries not supported by Onfido\b/],
            dog                        => {
                timing => undef,
                inc    => {
                    'onfido.unsupported_country' => {
                        tags => ['gb'],
                    },
                }
            },
            trace => {
                _send_email_onfido_unsupported_country_cs => 1,
            },
            result => undef,
        },
        {
            title  => 'Unsupported POB country uploaded by staff',
            client => {
                place_of_birth => 'wa',
                residence      => 'gb',
                email          => 'test2@binary.com',
                broker_code    => 'MX',
            },
            uploaded_manually_by_staff => 1,
            is_country_supported       => 0,
            logs                       => [qr/\bDocument not uploaded to Onfido as client is from list of countries not supported by Onfido\b/],
            dog                        => {
                timing => undef,
                inc    => {
                    'onfido.unsupported_country' => {
                        tags => ['wa'],
                    },
                }
            },
            trace => {

            },
            result => undef,
        },
        {
            title   => 'Unsupported selected country not uploaded by staff',
            country => 'aq',
            client  => {
                place_of_birth => 'gb',
                residence      => 'gb',
                email          => 'test8@binary.com',
                broker_code    => 'MX',
            },
            uploaded_manually_by_staff => 0,
            is_country_supported       => 0,
            logs                       => [qr/\bDocument not uploaded to Onfido as client is from list of countries not supported by Onfido\b/],
            dog                        => {
                timing => undef,
                inc    => {
                    'onfido.unsupported_country' => {
                        tags => ['aq'],
                    },
                }
            },
            trace => {
                _send_email_onfido_unsupported_country_cs => 1,
            },
            result => undef,
        },
        {
            title   => 'Unsupported selected country uploaded by staff',
            country => 'ng',
            client  => {
                place_of_birth => 'wa',
                residence      => 'gb',
                email          => 'test9@binary.com',
                broker_code    => 'MX',
            },
            uploaded_manually_by_staff => 1,
            is_country_supported       => 0,
            logs                       => [qr/\bDocument not uploaded to Onfido as client is from list of countries not supported by Onfido\b/],
            dog                        => {
                timing => undef,
                inc    => {
                    'onfido.unsupported_country' => {
                        tags => ['ng'],
                    },
                }
            },
            trace => {

            },
            result => undef,
        },
        {
            title  => 'Supported country and applicant already exists',
            client => {
                place_of_birth => 'gb',
                residence      => 'gb',
                email          => 'test3@binary.com',
                broker_code    => 'MX',
            },
            uploaded_manually_by_staff => 0,
            is_country_supported       => 1,
            logs                       => [qr/\bApplicant id already exists, returning that instead of creating new one\b/,],
            dog                        => {
                timing => undef,
                inc    => undef,
            },
            trace  => {},
            result => {
                applicant_exists => 1,
                applicant_id     => 'test1',
            },
        },
        {
            title  => 'Supported country and applicant does not exist',
            client => {
                place_of_birth => 'gb',
                residence      => 'gb',
                email          => 'test4@binary.com',
                broker_code    => 'MX',
            },
            uploaded_manually_by_staff => 0,
            is_country_supported       => 1,
            logs                       => [],
            dog                        => {
                timing => {
                    'event.document_upload.onfido.applicant_create.done.elapsed' => re('\d+'),
                },
                inc => undef,
            },
            trace  => {},
            result => {
                applicant_exists => 0,
                applicant_id     => 'test2',
            },
        },
        {
            title  => 'Supported country and applicant does not exist but undef applicant was created',
            client => {
                place_of_birth => 'gb',
                residence      => 'gb',
                email          => 'test5@binary.com',
                broker_code    => 'MX',
            },
            uploaded_manually_by_staff => 0,
            is_country_supported       => 1,
            logs                       => [],
            dog                        => {
                timing => {
                    'event.document_upload.onfido.applicant_create.failed.elapsed' => re('\d+'),
                },
                inc => undef,
            },
            trace  => {},
            result => {
                applicant_exists => 0,
                applicant_id     => undef,
            },
        },
        {
            title  => 'Non http exception happens',
            client => {
                place_of_birth => 'gb',
                residence      => 'gb',
                email          => 'test6@binary.com',
                broker_code    => 'MX',
            },
            uploaded_manually_by_staff => 0,
            is_country_supported       => 1,
            logs                       => [qr/\bgot so far\b/],
            dog                        => {
                timing => undef,
                inc    => undef,
            },
            trace      => {},
            result     => undef,
            exceptions => {
                onfido_exception => 'got so far',
            }
        },
        {
            title  => 'Http exception happens',
            client => {
                place_of_birth => 'gb',
                residence      => 'gb',
                email          => 'test7@binary.com',
                broker_code    => 'MX',
            },
            uploaded_manually_by_staff => 0,
            is_country_supported       => 1,
            logs                       => [qr/\bsome exception\b/, qr/\bOnfido http exception: .*invalid postcode.*\b/,],
            dog                        => {
                timing => undef,
                inc    => undef,
            },
            trace      => {},
            result     => undef,
            exceptions => {
                onfido_http_exception => {
                    error => {
                        type    => 'validation_error',
                        message => 'There was a validation error on this request',
                        fields  => {
                            addresses => [{
                                    postcode => ['invalid postcode'],
                                }
                            ],
                        },
                    },
                },
            },
        },
    ];

    for my $test ($tests->@*) {
        my ($title, $country, $client_data, $uploaded_manually_by_staff, $country_supported, $logs, $dog, $result, $trace, $exceptions) =
            @{$test}{qw/title country client uploaded_manually_by_staff is_country_supported logs dog result trace exceptions/};
        $is_country_supported  = $country_supported;
        $onfido_exception      = $exceptions->{onfido_exception};
        $onfido_http_exception = $exceptions->{onfido_http_exception};

        subtest $title => sub {
            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client($client_data);
            my $user   = BOM::User->create(
                email          => $client->email,
                password       => "hello",
                email_verified => 1,
            );

            if (defined $result) {
                ($applicant_exists, $applicant_id) = @{$result}{qw/applicant_exists applicant_id/};
            }

            $stats_timing    = undef;
            $stats_inc       = undef;
            $traced_subs     = {};
            $store_applicant = [];
            $log->clear();

            my $applicant = BOM::Event::Actions::Client::_get_onfido_applicant(
                client                     => $client,
                onfido                     => $onfido,
                uploaded_manually_by_staff => $uploaded_manually_by_staff,
                country                    => $country
            )->get;

            if (not defined $result) {
                is $applicant, undef, 'No applicant returned';
            } else {
                if ($applicant) {
                    isa_ok $applicant, 'WebService::Async::Onfido::Applicant', 'Expected class';
                    is $applicant->id, $applicant_id, 'Expected applicant id';

                    if ($applicant_exists) {
                        cmp_deeply $store_applicant, [], 'Existing applicant is not stored';
                    } else {
                        cmp_deeply $store_applicant, [$applicant, $client->binary_user_id,], 'New applicant stored';
                    }
                } else {
                    cmp_deeply $store_applicant, [], 'Cannot store undefined applicant';
                }
            }

            cmp_deeply $stats_timing, $dog->{timing}, 'Expected stats_timing';
            cmp_deeply $stats_inc,    $dog->{inc},    'Expected stats_inc';

            for my $expected_log ($logs->@*) {
                $log->contains_ok($expected_log, 'Expected log found');
            }

            cmp_deeply $traced_subs, $trace, 'Expected trace';
        };
    }

    $config_mock->unmock_all;
    $dog_mock->unmock_all;
    $event_mock->unmock_all;
};

$s3_mocker->unmock_all;

done_testing();
