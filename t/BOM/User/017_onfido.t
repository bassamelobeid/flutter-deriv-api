use strict;
use warnings;
use Test::More tests => 20;
use Test::MockTime qw( :all );
use Test::Exception;
use Test::NoWarnings;
use Test::Warn;
use Test::Warnings;
use Test::Deep;
use Test::MockModule;
use Log::Any::Test;
use Log::Any        qw($log);
use JSON::MaybeUTF8 qw(encode_json_utf8);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::OnfidoMock;

use BOM::User::Onfido;
use WebService::Async::Onfido;
use Date::Utility;
use BOM::Database::UserDB;

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $test_user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);
$test_user->add_client($test_client);
$test_client->place_of_birth('cn');
$test_client->binary_user_id($test_user->id);
$test_client->save;

my $loop = IO::Async::Loop->new;
$loop->add(
    my $onfido = WebService::Async::Onfido->new(
        token    => 'test_token',
        base_uri => $ENV{ONFIDO_URL}));

my $app1 = $onfido->applicant_create(
    title      => 'Mr',
    first_name => $test_client->first_name,
    last_name  => $test_client->last_name,
    email      => $test_client->email,
    gender     => $test_client->gender,
    dob        => '1980-01-22',
    country    => 'GBR',
    addresses  => [{
            building_number => '100',
            street          => 'Main Street',
            town            => 'London',
            postcode        => 'SW4 6EH',
            country         => 'GBR',
        }
    ],
)->get;

my $app2 = $onfido->applicant_create(
    title      => 'Mr',
    first_name => $test_client->first_name,
    last_name  => $test_client->last_name,
    email      => $test_client->email,
    gender     => $test_client->gender,
    dob        => '1980-01-22',
    country    => 'GBR',
    addresses  => [{
            building_number => '100',
            street          => 'Main Street',
            town            => 'London',
            postcode        => 'SW4 6EH',
            country         => 'GBR',
        }
    ],
)->get;

subtest 'store & get onfido applicant' => sub {
    throws_ok {
        warning_like { BOM::User::Onfido::store_onfido_applicant($app1, 123456); }
        qr/insert or update on table "onfido_applicant" violates foreign key constraint/s, "have warning";
    }
    qr/Fail to store Onfido/, 'incorrect user_id will cause exception';
    lives_ok { BOM::User::Onfido::store_onfido_applicant($app1, $test_client->binary_user_id); } 'now storing onfido should pass';
    lives_ok { BOM::User::Onfido::store_onfido_applicant($app2, $test_client->binary_user_id); } 'store app2 ';
    throws_ok { warning_like { BOM::User::Onfido::get_all_user_onfido_applicant("hello"); } qr/invalid input syntax for integer/, 'there is warn' }
    qr/Please check USER_ID/, 'incorrect user-id will cause exception';
    my $result = BOM::User::Onfido::get_all_user_onfido_applicant($test_client->binary_user_id);
    ok($result, 'now has result when getting applicant');
    is_deeply([sort keys %$result], [sort ($app1->id, $app2->id)], 'applicants correct');
};

subtest 'store & get onfido live photo' => sub {
    my @photos;
    for (1 .. 2) {
        my $photo = $onfido->live_photo_upload(
            applicant_id => $app1->id,
            filename     => 'photo1.jpg',
            data         => 'photo ' x 50
        )->get;
        lives_ok { BOM::User::Onfido::store_onfido_live_photo($photo, $app1->id); } 'Storing onfido live photo should pass';
        push @photos, $photo;
    }
    my $result;
    lives_ok { $result = BOM::User::Onfido::get_onfido_live_photo($test_client->binary_user_id, $app1->id); } 'Storing onfido live photo should pass';
    is_deeply([sort keys %$result], [sort map { $_->id } @photos], 'the result of get photo ok');
};

my ($doc1, $doc2);

subtest 'store & get onfido document' => sub {
    $doc1 = $onfido->document_upload(
        applicant_id    => $app1->id,
        filename        => "document1.png",
        type            => 'passport',
        issuing_country => 'China',
        data            => 'This is passport',
        side            => 'front',
    )->get;
    $doc2 = $onfido->document_upload(
        applicant_id    => $app1->id,
        filename        => "document2.png",
        type            => 'driving_licence',
        issuing_country => 'China',
        data            => 'This is driving_licence',
        side            => 'front',
    )->get;
    lives_ok { BOM::User::Onfido::store_onfido_document($doc1, $app1->id, $test_client->place_of_birth, $doc1->type, $doc1->side); }
    'Storing onfido document should pass';
    lives_ok { BOM::User::Onfido::store_onfido_document($doc2, $app1->id, $test_client->place_of_birth, $doc2->type, $doc2->side); }
    'Storing onfido document should pass';
    my $result;
    lives_ok { $result = BOM::User::Onfido::get_onfido_document($test_client->binary_user_id, $app1->id); } 'Storing onfido live photo should pass';
    is_deeply([sort keys %$result], [sort $doc1->id, $doc2->id], 'the result of get photo ok');
};

subtest 'store onfido v2' => sub {
    my $result;

    my $document = {
        id              => 'test',
        document_type   => 'passport',
        issuing_country => 'br',
        document_number => '000-0-0',
        date_of_expiry  => '2000-10-10',
        document_side   => 'front',
        file_type       => 'png',
        applicant_id    => $app1->id,
        result          => 'consider',
        created_at      => '2023-07-07T14:12:23Z',
        href            => '/v3.6/documents/test',
        download_href   => '/v3.6/documents/test/download',
        file_name       => 'test.png',
        file_size       => 1024,
    };

    lives_ok { BOM::User::Onfido::store_onfido_document_v2($document); }
    'Storing onfido document should pass';

    lives_ok { $result = BOM::User::Onfido::get_onfido_document($test_client->binary_user_id, $app1->id); } 'Retrieving documents for applicant';

    # some manipulation to make it match
    $document->{created_at}      = Date::Utility->new($document->{created_at})->datetime_yyyymmdd_hhmmss;
    $document->{api_type}        = $document->{document_type};
    $document->{side}            = $document->{document_side};
    $document->{stamp}           = re('.*');
    $document->{issuing_country} = 'BRA';

    cmp_deeply $result->{test},
        +{%{$document}{qw/created_at id api_type issuing_country href applicant_id side stamp file_type download_href file_size file_type file_name/}
        }, 'expected document';

    subtest 'undef issuing country' => sub {
        $document = {
            id              => 'test2',
            document_type   => 'passport',
            issuing_country => undef,
            document_number => '000-0-0',
            date_of_expiry  => '2000-10-10',
            document_side   => 'front',
            file_type       => 'png',
            applicant_id    => $app1->id,
            result          => 'consider',
            created_at      => '2023-07-07T14:12:23Z',
            href            => '/v3.6/documents/test2',
            download_href   => '/v3.6/documents/test2/download',
            file_name       => 'test2.png',
            file_size       => 1024,
        };

        lives_ok { BOM::User::Onfido::store_onfido_document_v2($document); }
        'Storing onfido document should pass';

        lives_ok { $result = BOM::User::Onfido::get_onfido_document($test_client->binary_user_id, $app1->id); } 'Retrieving documents for applicant';

        # some manipulation to make it match
        $document->{created_at}      = Date::Utility->new($document->{created_at})->datetime_yyyymmdd_hhmmss;
        $document->{api_type}        = $document->{document_type};
        $document->{side}            = $document->{document_side};
        $document->{stamp}           = re('.*');
        $document->{issuing_country} = '';

        cmp_deeply $result->{test2},
            +{%{$document}
                {qw/created_at id api_type issuing_country href applicant_id side stamp file_type download_href file_size file_type file_name/}
            }, 'expected document';

    };
};

my $check;
subtest 'store & update & fetch check ' => sub {
    $check = $onfido->applicant_check(
        applicant_id => $app1->id,
        # We don't want Onfido to start emailing people
        suppress_form_emails => 1,
        # Used for reporting and filtering in the web interface
        tags => ['tag1', 'tag2'],
        # On v3 we need to specify the array of documents
        document_ids => [$doc1->id, $doc2->id],
        # On v3 we need to specify the report names
        report_names               => [qw/document facial_similarity_photo/],
        suppress_from_email        => 0,
        charge_applicant_for_check => 0,
    )->get;
    $check->{status} = 'in_progress';
    lives_ok { BOM::User::Onfido::store_onfido_check($app1->id, $check); } 'Storing onfido check should pass';
    my $result;
    lives_ok { $result = BOM::User::Onfido::get_latest_onfido_check($test_client->binary_user_id); } 'get latest onfido check should pass';

    my $first_check_by_id = BOM::User::Onfido::get_onfido_check($test_client->binary_user_id, $app1->id, "notid");

    is $first_check_by_id->{id}, undef, 'Check was not found in DB';

    my $check_by_id = BOM::User::Onfido::get_onfido_check($test_client->binary_user_id, $app1->id, $check->id);

    is $check_by_id->{id}, $check->id, 'Check was found in DB';

    is($result->{id},       $check->id,    'get latest onfido check result ok');
    is($result->{status},   'in_progress', 'the status of check is in_progress');
    is($result->{api_type}, 'deprecated',  'type got deprecated in v3');
    $check->{status} = 'complete';
    lives_ok { BOM::User::Onfido::update_onfido_check($check) } 'update check ok';
    lives_ok { $result = BOM::User::Onfido::get_latest_onfido_check($test_client->binary_user_id); } 'get check again';
    is($result->{status}, 'complete', 'the status of check is complete');
};

subtest 'store & fetch report' => sub {
    my @all_report = $check->reports->as_list->get;
    for my $report (@all_report) {
        $report->{breakdown}  = {};
        $report->{properties} = {};
        lives_ok { BOM::User::Onfido::store_onfido_report($check, $report) } 'store report ok';
    }
    my $result;

    lives_ok { $result = BOM::User::Onfido::get_all_onfido_reports($test_client->binary_user_id, $check->id) } "get report ok";

    is_deeply([sort keys %$result], [sort map { $_->id } @all_report], 'getting all reports ok');
};

subtest 'limits per user' => sub {
    is BOM::User::Onfido::limit_per_user,   2,       'The allowed submissions counter is 2 by default';
    is BOM::User::Onfido::timeout_per_user, 1296000, '15 days to reset the counter';
};

subtest 'submissions left per user' => sub {
    $test_client->residence('gh');
    $test_client->save;
    my $limit = BOM::User::Onfido::limit_per_user($test_client->residence);
    is $limit, 1, '1 is the correct number of attempst for IDV supported countries';

    $test_client->residence('id');
    $test_client->save;
    $limit = BOM::User::Onfido::limit_per_user($test_client->residence);
    is $limit, 1, '1 is the correct number of attempst for IDV supported countries';

    $test_client->residence('py');
    $test_client->save;
    $limit = BOM::User::Onfido::limit_per_user($test_client->residence);
    is $limit, 2, '2 is the correct number of attempst for non IDV supported countries';

    is BOM::User::Onfido::submissions_left($test_client), $limit, 'The client has all the submissions left';

    my $submissions_used = 0;
    my $redis_mock       = Test::MockModule->new('RedisDB');
    $redis_mock->mock(
        'get',
        sub {
            return $submissions_used;
        });

    foreach my $i (1 .. 2) {
        $submissions_used++;
        is BOM::User::Onfido::submissions_left($test_client), $limit - $submissions_used, 'Submissions left are looking good';

    }

    $redis_mock->unmock_all;
};

subtest 'submissions reset at user' => sub {
    my $limit = BOM::User::Onfido::limit_per_user();
    is BOM::User::Onfido::submissions_left($test_client), $limit, 'The client has all the submissions left';

    my $submissions_used = 0;
    my $redis_mock       = Test::MockModule->new('RedisDB');
    my $time             = time;
    $redis_mock->mock(
        'ttl',
        sub {
            $time += 100;
            return 100;    # seconds
        });

    is BOM::User::Onfido::submissions_reset_at($test_client), Date::Utility->new($time), 'Reset at time is looking good';

    $redis_mock->unmock_all;
};

subtest 'get consider reasons' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'qwerty@asdf.com'
    });

    my $test_user = BOM::User->create(
        email          => $test_client->email,
        password       => 'hey you',
        email_verified => 1,
    );
    $test_user->add_client($test_client);
    $test_client->binary_user_id($test_user->id);
    $test_client->save;

    # Do the needful mocks

    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my $check_result;
    $onfido_mock->mock(
        'get_latest_onfido_check',
        sub {
            return {
                id     => 'TESTING',
                status => 'complete',
                result => $check_result // 'consider',
            };
        });

    # the report must include valid properties for the comparison check
    my $properties = {
        first_name => $test_client->first_name,
        last_name  => $test_client->last_name,
    };

    # Every possible reason is here

    my $breakdowns = {
        data_comparison => {
            first_name       => 1,
            last_name        => 1,
            date_of_birth    => 1,
            issuing_country  => 1,
            document_type    => 1,
            document_numbers => 1,
        },
        visual_authenticity => {
            original_document_present => [qw/photo_of_screen screenshot document_on_printed_paper scan/],
            fonts                     => 1,
            picture_face_integrity    => 1,
            template                  => 1,
            security_features         => 1,
            digital_tampering         => 1,
            other                     => 1,
            face_detection            => 1,
        },
        data_validation => {
            gender              => 1,
            document_numbers    => 1,
            document_expiration => 1,
            expiry_date         => 1,
            mrz                 => 1,
        },
        image_integrity => {
            conclusive_document_quality => [
                qw/obscured_data_points obscured_security_features abnormal_document_features watermarks_digital_text_overlay corner_removed punctured_document missing_back digital_document/
            ],
            image_quality => [
                qw/dark_photo glare_on_photo blurred_photo covered_photo other_photo_issue damaged_document incorrect_side cut_off_document no_document_in_image two_documents_uploaded/
            ],
            supported_document => 1,
            colour_picture     => 1,
        },
        data_consistency => {
            date_of_expiry   => 1,
            document_numbers => 1,
            issuing_country  => 1,
            document_type    => 1,
            date_of_birth    => 1,
            gender           => 1,
            first_name       => 1,
            last_name        => 1,
            nationality      => 1,
        },
        age_validation => {
            minimum_accepted_age => 1,
        },
        compromised_document => 1
    };

    # Cases to test

    my $cases = [{
            test       => 'Testing empty reasons',
            reasons    => [],
            breakdown  => {},
            properties => $properties,
        }];

    # Breakdown payload builder

    my $breakdown_builder = sub {
        my ($breakdown, $sub_breakdown, $properties) = @_;
        return +{
            $breakdown => {
                result    => 'consider',
                breakdown => {
                    $sub_breakdown => {
                        result     => 'consider',
                        properties => $properties // {},
                    }}}};
    };

    # Create a case for each possible reason
    for my $breakdown (keys $breakdowns->%*) {
        if (ref($breakdowns->{$breakdown}) eq 'HASH') {
            for my $sub_breakdown (keys $breakdowns->{$breakdown}->%*) {
                my $reasons = $breakdowns->{$breakdown}->{$sub_breakdown};

                if (ref($reasons) eq 'ARRAY') {
                    for my $reason ($breakdowns->{$breakdown}->{$sub_breakdown}->@*) {
                        my $breakdown_payload = $breakdown_builder->(
                            $breakdown,
                            $sub_breakdown,
                            {
                                $reason => 'consider',
                            });

                        push @$cases,
                            {
                            test       => 'Testing reason ' . $reason,
                            properties => $properties,
                            reasons    =>
                                [join('.', $breakdown), join('.', $breakdown, $sub_breakdown), join('.', $breakdown, $sub_breakdown, $reason),],
                            breakdown => $breakdown_payload,
                            };
                    }
                } else {
                    my $breakdown_payload = $breakdown_builder->($breakdown, $sub_breakdown);

                    push @$cases,
                        {
                        test       => 'Testing reason ' . $sub_breakdown,
                        properties => $properties,
                        reasons    => [join('.', $breakdown), join('.', $breakdown, $sub_breakdown),],
                        breakdown  => $breakdown_payload,
                        };
                }

            }
        } else {
            push @$cases,
                {
                test       => 'Testing reason ' . $breakdown,
                reasons    => [$breakdown],
                properties => $properties,
                breakdown  => {
                    $breakdown => {
                        result => 'consider',
                    }
                },
                };
        }
    }

    # Create some multi reason cases
    # Note only "consider" breakdowns -> sub-breakdowns -> reasons are added to the expected result

    push @$cases, {
        test    => 'Testing multiple reasons',
        reasons => [
            qw/
                image_integrity
                image_integrity.image_quality
                image_integrity.image_quality.blurred_photo
                image_integrity.image_quality.dark_photo
                visual_authenticity
                visual_authenticity.original_document_present
                visual_authenticity.original_document_present.screenshot/
        ],
        properties => $properties,
        breakdown  => {
            visual_authenticity => {
                result    => 'consider',
                breakdown => {
                    original_document_present => {
                        result     => 'consider',
                        properties => {screenshot => 'consider'},
                    }}
            },
            image_integrity => {
                result    => 'consider',
                breakdown => {
                    image_quality => {
                        result     => 'consider',
                        properties => {
                            dark_photo     => 'consider',
                            glare_on_photo => 'clear',
                            blurred_photo  => 'consider',
                        },
                    },
                    conclusive_document_quality => {
                        result     => 'clear',
                        properties => {
                            obscured_data_points => 'clear',
                        },
                    },
                }
            },
        },
    };

    # Special case null document numbers

    push @$cases,
        {
        test       => 'Testing special case null document numbers',
        reasons    => [qw/data_validation data_validation.no_document_numbers/],
        properties => $properties,
        breakdown  => {
            data_validation => {
                result    => 'consider',
                breakdown => {
                    document_numbers => {
                        result => undef,
                    }}
            },
        },
        };

    # duplicated document
    push @$cases,
        {
        test       => 'Testing duplicated document scenario',
        reasons    => [qw/duplicated_document/],
        result     => 'clear',
        properties => {},
        breakdown  => {},
        status     => [qw/poi_duplicated_documents/]};
    push @$cases,
        {
        test       => 'Testing duplicated document scenario (no status = no reason)',
        reasons    => [qw//],
        result     => 'clear',
        properties => {},
        breakdown  => {},
        };

    # Perform the test

    subtest 'Breakdown coverage' => sub {
        foreach my $case ($cases->@*) {
            $test_client->status->set($_, 'system', 'test') for ($case->{status}->@*);
            $test_client  = BOM::User::Client->new({loginid => $test_client->loginid});
            $check_result = $case->{result};

            $onfido_mock->mock(
                'get_all_onfido_reports',
                sub {
                    return {
                        TESTING => {
                            result     => 'consider',
                            api_name   => 'document',
                            breakdown  => encode_json_utf8($case->{breakdown}),
                            properties => encode_json_utf8($case->{properties}),
                        },
                    };
                });
            my $reasons = BOM::User::Onfido::get_consider_reasons($test_client);
            cmp_deeply($reasons, set($case->{reasons}->@*), $case->{test});

            $test_client->propagate_clear_status($_) for ($case->{status}->@*);
        }
    };

    # Selfie case
    $check_result = undef;

    subtest 'Selfie coverage' => sub {
        my $tests = [{
                reasons => [qw/selfie/],
                reports => {
                    SELFIE => {
                        result   => 'consider',
                        api_name => 'facial_similarity',
                    }
                },
                test => 'Selfie issues'
            },
            {
                reasons => [
                    qw/
                        selfie
                        visual_authenticity
                        visual_authenticity.original_document_present
                        visual_authenticity.original_document_present.document_on_printed_paper/
                ],
                reports => {
                    SELFIE => {
                        result   => 'consider',
                        api_name => 'facial_similarity',
                    },
                    DOC => {
                        result     => 'consider',
                        api_name   => 'document',
                        properties => encode_json_utf8($properties),
                        breakdown  => encode_json_utf8({
                                visual_authenticity => {
                                    result    => 'consider',
                                    breakdown => {
                                        original_document_present => {
                                            result     => 'consider',
                                            properties => {document_on_printed_paper => 'consider'},
                                        }}
                                },
                            }
                        ),
                    }
                },
                test => 'Selfie issues mixed with documents issues'
            }];

        foreach my $test ($tests->@*) {
            $onfido_mock->mock(
                'get_all_onfido_reports',
                sub {
                    return $test->{reports};
                });

            my $reasons = BOM::User::Onfido::get_consider_reasons($test_client);

            cmp_deeply($reasons, set($test->{reasons}->@*), $test->{test});
        }
    };

    # Cover all execution branches

    subtest 'Cover all execution branches' => sub {
        $onfido_mock->mock(
            'get_latest_onfido_check',
            sub {
                return {
                    id     => 'TESTING',
                    status => 'pending',
                    result => 'none',
                };
            });

        my $reasons = BOM::User::Onfido::get_consider_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'Pending check has empty results');

        $onfido_mock->mock(
            'get_latest_onfido_check',
            sub {
                return {
                    id     => 'TESTING',
                    status => 'complete',
                    result => 'clear',
                };
            });

        $reasons = BOM::User::Onfido::get_consider_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'A clear check has empty results');

        $onfido_mock->mock(
            'get_latest_onfido_check',
            sub {
                return {
                    id     => 'TESTING',
                    status => 'complete',
                    result => 'consider',
                };
            });

        $onfido_mock->mock(
            'get_all_onfido_reports',
            sub {
                return {};
            });

        $reasons = BOM::User::Onfido::get_consider_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'Empty results if no report found');

        $onfido_mock->mock(
            'get_all_onfido_reports',
            sub {
                return {
                    TESTING => {
                        api_name => 'other',
                    }};
            });

        $reasons = BOM::User::Onfido::get_consider_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'Empty results for api_name other');

        $onfido_mock->mock(
            'get_all_onfido_reports',
            sub {
                return {
                    TESTING => {
                        api_name   => 'document',
                        result     => 'clear',
                        properties => encode_json_utf8($properties),
                    }};
            });

        $reasons = BOM::User::Onfido::get_consider_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'Empty results for clear report');
    };

    # Bogus breakdowns should not kill

    subtest 'Unexpected format' => sub {
        my $hit_dd;

        $onfido_mock->mock(
            'get_latest_onfido_check',
            sub {
                return {
                    id     => 'TESTING',
                    status => 'complete',
                    result => 'consider',
                };
            });
        $onfido_mock->mock(
            'stats_inc',
            sub {
                $hit_dd = 1;
                return undef;
            });

        my $tests = [{
                payload => {
                    test => {

                    },
                },
                reasons => [],
                hit_dd  => 0,
            },
            {
                payload => {result => 'test'},
                reasons => [],
                hit_dd  => 0,
            },
            {
                payload => 0,
                reasons => [],
                hit_dd  => 1,
            },
            {
                payload => undef,
                reasons => [],
                hit_dd  => 0,
            },
            {
                payload => '',
                reasons => [],
                hit_dd  => 1,
            },
            {
                payload => 'hello world',
                reasons => [],
                hit_dd  => 1,
            },
            {
                payload => {a => {breakdown => undef}},
                reasons => [],
                hit_dd  => 0,
            },
            {
                payload => {breakdown => 1},
                reasons => [],
                hit_dd  => 0,
            },
            {
                payload => {a => {properties => [1, 2, 3]}},
                reasons => [],
                hit_dd  => 0,
            },
            {
                payload => {
                    a => {
                        result     => 'consider',
                        properties => [1, 2, 3]}
                },
                reasons => [qw/a/],
                hit_dd  => 0,
            },
            {
                payload => {
                    a => {
                        result     => 'consider',
                        properties => {
                            c => 'consider',
                            b => {}}}
                },
                reasons => [qw/a a.c/],
                hit_dd  => 0,
            },
            {
                payload => {properties => [qw/a b c/]},
                reasons => [],
                hit_dd  => 0,
            }];

        for my $test ($tests->@*) {
            $onfido_mock->mock(
                'get_all_onfido_reports',
                sub {
                    return {
                        DOC => {
                            result     => 'consider',
                            api_name   => 'document',
                            properties => encode_json_utf8($properties),
                            breakdown  => ref($test->{payload}) ? encode_json_utf8($test->{payload}) : $test->{payload},
                        }};
                });

            $hit_dd = 0;

            lives_ok {
                my $reasons = BOM::User::Onfido::get_consider_reasons($test_client);
                cmp_deeply($reasons, set($test->{reasons}->@*), 'Expected results for bogus breakdown');
            }
            'Bogus breakdown should not kill';

            is $hit_dd, $test->{hit_dd}, $test->{hit_dd} ? 'Dog correctly annoyed' : 'The good boy has deep sleep';
        }
    };

    subtest 'Get reported properties' => sub {
        my $check;
        my $properties;

        my $tests = [{
                check      => undef,
                properties => {
                    a => 1,
                },
                reported => {},
            },
            {
                check      => {},
                properties => {
                    a => 1,
                },
                reported => {},
            },
            {
                check => {
                    id => undef,
                },
                properties => {
                    a => 1,
                },
                reported => {},
            },
            {
                check => {
                    id => 'test',
                },
                properties => {first_name => 'husky'},
                reported   => {first_name => 'husky'},
            },
            {
                check => {
                    id => 'test',
                },
                properties => {
                    first_name => 'husky',
                    last_name  => 'dusky',
                },
                reported => {
                    first_name => 'husky',
                    last_name  => 'dusky',
                },
            },
            {
                check => {
                    id => 'test',
                },
                properties => {
                    first_name => 'husky',
                    last_name  => 'dusky',
                    other      => 'dusty',
                },
                reported => {
                    first_name => 'husky',
                    last_name  => 'dusky',
                },
            },
            {
                check => {
                    id => 'test',
                },
                properties => {
                    first_name    => 'husky',
                    last_name     => 'dusky',
                    other         => 'dusty',
                    date_of_birth => '1999-10-10'
                },
                reported => {
                    first_name    => 'husky',
                    last_name     => 'dusky',
                    date_of_birth => '1999-10-10'
                },
            }];

        $onfido_mock->mock(
            'get_latest_onfido_check',
            sub {
                return $check;
            });

        $onfido_mock->mock(
            'get_all_onfido_reports',
            sub {
                return {
                    DOC => {
                        result     => 'consider',
                        api_name   => 'document',
                        properties => encode_json_utf8($properties),
                    }};
            });

        for my $test ($tests->@*) {
            $properties = $test->{properties};
            $check      = $test->{check};
            cmp_deeply(BOM::User::Onfido::reported_properties($test_client), $test->{reported}, 'Expected reported properties seen');
        }
        $onfido_mock->unmock_all;
    };

    subtest 'update full name based on Onfido reported properties' => sub {
        my $check;
        my $properties;
        my $reported;

        $onfido_mock->mock(
            'get_latest_onfido_check',
            sub {
                return $check;
            });

        $onfido_mock->mock(
            'get_all_onfido_reports',
            sub {
                return {
                    DOC => {
                        result     => 'clear',
                        api_name   => 'document',
                        properties => encode_json_utf8($properties),
                    }};
            });

        $test_client->first_name('Elian');
        $test_client->last_name('Valenzuela');

        $check = {
            id => 'test',
        };

        #case when the properties are missing

        $properties = {
            first_name => '',
            last_name  => '',
        };

        is BOM::User::Onfido::update_full_name_from_reported_properties($test_client), 0, 'Missing properties in passed args';

        #case when the first name and last name are different

        $properties = {
            first_name => 'ELIAN ANGEL',
            last_name  => 'VALENZUELA TURRO',
        };

        is BOM::User::Onfido::update_full_name_from_reported_properties($test_client), 1,                  'executed successfully';
        is $test_client->first_name,                                                   'Elian Angel',      'first name updated';
        is $test_client->last_name,                                                    'Valenzuela Turro', 'last name updated';

        #case when the first name and last name are inverted

        $test_client->first_name('valenzuela');
        $test_client->last_name('elian angel');

        is BOM::User::Onfido::update_full_name_from_reported_properties($test_client), 1,                  'executed successfully';
        is $test_client->first_name,                                                   'Elian Angel',      'first name updated';
        is $test_client->last_name,                                                    'Valenzuela Turro', 'last name updated';

        #case when first name is equal but last name is not

        $test_client->first_name('elian angel');
        $test_client->last_name('valen');

        $properties = {
            first_name => 'ELIAN ANGEL',
            last_name  => 'VALENZUELA TURRO',
        };

        is BOM::User::Onfido::update_full_name_from_reported_properties($test_client), 1,                  'executed successfully';
        is $test_client->first_name,                                                   'elian angel',      'first name not updated';
        is $test_client->last_name,                                                    'Valenzuela Turro', 'last name updated';

        #case when last name is equal but first name is not

        $test_client->first_name('angel');
        $test_client->last_name('valenzuela turro');

        $properties = {
            first_name => 'ELIAN ANGEL',
            last_name  => 'VALENZUELA TURRO',
        };

        is BOM::User::Onfido::update_full_name_from_reported_properties($test_client), 1,                  'executed successfully';
        is $test_client->first_name,                                                   'Elian Angel',      'first name updated';
        is $test_client->last_name,                                                    'valenzuela turro', 'last name not updated';

        #case when first name or last name have more than 50 characters

        $test_client->first_name('this is a big name');
        $test_client->last_name('and this is a big last name');

        $properties = {
            first_name => 'this is a truly super duper ultra big very large and long name',
            last_name  => 'and this is a big last name',
        };

        is length($properties->{first_name}) > 50, 1, 'first name is longer than 50 characters';
        is length($properties->{last_name}) < 50,  1, 'last name is within 50 characters';

        is BOM::User::Onfido::update_full_name_from_reported_properties($test_client), 1,             'executed successfully';
        is $test_client->first_name,              'This Is A Truly Super Duper Ultra Big Very Large', 'first name updated';
        is length($test_client->first_name) < 50, 1,                                                  'first name was successfully trimmed';
        is $test_client->last_name,               'and this is a big last name',                      'last name not updated';
        is length($test_client->last_name) < 50,  1,                                                  'last name was not trimmed';

        $properties = {
            first_name => 'this is a big name',
            last_name  => 'and this is the same super long and suspiciously big last name',
        };

        is length($properties->{first_name}) < 50, 1, 'first name is within 50 characters';
        is length($properties->{last_name}) > 50,  1, 'last name is longer than 50 characters';

        is BOM::User::Onfido::update_full_name_from_reported_properties($test_client), 1,                    'executed successfully';
        is $test_client->first_name,                                                   'This Is A Big Name', 'first name not updated';
        is length($test_client->first_name) < 50,                                      1,                    'first name was not trimmed';
        is $test_client->last_name,              'And This Is The Same Super Long And Suspiciously',         'last name updated';
        is length($test_client->last_name) < 50, 1,                                                          'last name  was successfully trimmed';

        #case when both first name and last name have more than 50 characters

        $test_client->first_name('this is a big name');
        $test_client->last_name('and this is a big last name');

        $properties = {
            first_name => 'this is a truly super duper ultra big very large and long name',
            last_name  => 'and this is the same super long and suspiciously big last name',
        };

        is length($properties->{first_name}) > 50, 1, 'first name is longer than 50 characters';
        is length($properties->{last_name}) > 50,  1, 'last name is longer than 50 characters';

        is BOM::User::Onfido::update_full_name_from_reported_properties($test_client), 1,             'executed successfully';
        is $test_client->first_name,              'This Is A Truly Super Duper Ultra Big Very Large', 'first name updated';
        is length($test_client->first_name) < 50, 1,                                                  'first name was successfully trimmed';
        is $test_client->last_name,               'And This Is The Same Super Long And Suspiciously', 'last name updated';
        is length($test_client->last_name) < 50,  1,                                                  'last name was successfully trimmed';

    };

    subtest 'Get our own rules reasons (Name Mismatch)' => sub {
        my $reasons;
        my $poi_name_mismatch;

        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
        $status_mock->mock(
            'poi_name_mismatch',
            sub {
                return $poi_name_mismatch;
            });

        my $provider;
        my $client_mock = Test::MockModule->new('BOM::User::Client');
        $client_mock->mock(
            'latest_poi_by',
            sub {
                return ($provider);
            });

        $provider          = 'onfido';
        $poi_name_mismatch = 1;
        $reasons           = BOM::User::Onfido::get_rules_reasons($test_client);
        cmp_deeply($reasons, set(['data_comparison.first_name']->@*), 'Name mismatch reported');

        $provider = 'idv';
        $reasons  = BOM::User::Onfido::get_rules_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'No reason reported for Onfido');

        $provider          = 'onfido';
        $poi_name_mismatch = 0;
        $reasons           = BOM::User::Onfido::get_rules_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'No reason reported');

        $status_mock->unmock_all;
        $client_mock->unmock_all;
    };

    subtest 'Get our own rules reasons (DOB Mismatch)' => sub {
        my $reasons;
        my $poi_dob_mismatch;

        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
        $status_mock->mock(
            'poi_dob_mismatch',
            sub {
                return $poi_dob_mismatch;
            });

        my $provider;
        my $client_mock = Test::MockModule->new('BOM::User::Client');
        $client_mock->mock(
            'latest_poi_by',
            sub {
                return ($provider);
            });

        $provider         = 'onfido';
        $poi_dob_mismatch = 1;
        $reasons          = BOM::User::Onfido::get_rules_reasons($test_client);
        cmp_deeply($reasons, set(['data_comparison.date_of_birth']->@*), 'Dob mismatch reported');

        $provider = 'idv';
        $reasons  = BOM::User::Onfido::get_rules_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'No reason reported for Onfido');

        $provider         = 'onfido';
        $poi_dob_mismatch = 0;
        $reasons          = BOM::User::Onfido::get_rules_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'No reason reported');

        $status_mock->unmock_all;
        $client_mock->unmock_all;
    };

    subtest 'ready for auth' => sub {
        my $emit_mocker = Test::MockModule->new('BOM::Platform::Event::Emitter');
        my $emission;
        my $applicant_id;
        my $redis       = BOM::Config::Redis::redis_events();
        my $key         = +BOM::User::Onfido::ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id;
        my $pending_key = +BOM::User::Onfido::ONFIDO_REQUEST_PENDING_PREFIX . $test_client->binary_user_id;
        $redis->del($key);

        $onfido_mock->mock(
            'get_user_onfido_applicant',
            sub {
                return {id => $applicant_id};
            });

        $emit_mocker->mock(
            'emit',
            sub {
                $emission = +{@_};

                return 1;
            });

        $applicant_id = 'R01-x01';
        ok BOM::User::Onfido::ready_for_authentication($test_client), 'Ready for auth';

        cmp_deeply $emission,
            {
            ready_for_authentication => {
                loginid      => $test_client->loginid,
                applicant_id => $applicant_id,
            },
            },
            'Expected event emitted';

        ok $redis->get($pending_key), 'Expected pending flag';
        ok $redis->ttl($pending_key), 'TTL set';
        is $redis->get($key), 1, 'Expected counter initialized';
        ok $redis->ttl($key),                                                'TTL set';
        ok BOM::User::Onfido::pending_request($test_client->binary_user_id), 'Has a pending request';

        $applicant_id = 'R01-x01';
        $redis->del($pending_key);
        $emission = {};

        is BOM::User::Onfido::submissions_left($test_client), 0, 'submissions left at zero';
        ok !BOM::User::Onfido::pending_request($test_client->binary_user_id), 'Does not have a pending request';
        ok !BOM::User::Onfido::ready_for_authentication($test_client),        'Cannot underflow the submissions left counter';
        cmp_deeply $emission, {}, 'No emission';

        $redis->del($pending_key);
        $redis->del($key);
        $emission = {};
        is BOM::User::Onfido::submissions_left($test_client), 1, 'submissions left are back';
        ok !BOM::User::Onfido::pending_request($test_client->binary_user_id), 'Does not have a pending request';
        ok BOM::User::Onfido::ready_for_authentication($test_client),         'Ready for auth';

        cmp_deeply $emission,
            {
            ready_for_authentication => {
                loginid      => $test_client->loginid,
                applicant_id => $applicant_id,
            },
            },
            'Expected event emitted';

        ok $redis->get($pending_key), 'Expected pending flag';
        ok $redis->ttl($pending_key), 'TTL set';
        is $redis->get($key), 1, 'Counter increased';
        ok $redis->ttl($key), 'TTL set';

        $redis->del($pending_key);
        $redis->del($key);
        $test_client->residence('py');    # no idv supported
        $test_client->save;

        ok BOM::User::Onfido::ready_for_authentication($test_client, {documents => ['S3', 'X', 'Y']}), 'ready for auth';

        cmp_deeply $emission,
            {
            ready_for_authentication => {
                loginid      => $test_client->loginid,
                applicant_id => $applicant_id,
                documents    => ['S3', 'X', 'Y'],
            },
            },
            'Expected event emitted';

        ok $redis->get($pending_key), 'Expected pending flag';
        ok $redis->ttl($pending_key), 'TTL set';
        is $redis->get($key), 1, 'Counter increased';
        ok $redis->ttl($key), 'TTL set';

        $emission = {};
        $redis->del($pending_key);

        ok BOM::User::Onfido::ready_for_authentication($test_client, {documents => ['S3', 'X', 'Y']}), 'ready for auth';

        cmp_deeply $emission,
            {
            ready_for_authentication => {
                loginid      => $test_client->loginid,
                applicant_id => $applicant_id,
                documents    => ['S3', 'X', 'Y'],
            },
            },
            'Expected event emitted';

        ok $redis->get($pending_key), 'Expected pending flag';
        ok $redis->ttl($pending_key), 'TTL set';
        is $redis->get($key), 2, 'Counter increased';
        ok $redis->ttl($key), 'TTL set';

        subtest 'pending flag still alive' => sub {
            $log->clear();
            $emission = {};
            ok !BOM::User::Onfido::ready_for_authentication($test_client, {documents => ['S2', 'A', 'B']}), 'not ready for auth';
            cmp_deeply $emission, {}, 'No event emitted';
            is $redis->get($key), 2, 'Counter not increased';
            $log->does_not_contain_ok(qr/Unexpected Onfido request when pending flag is still alive/, 'warning log ok')
                ;    # log is skipped because the submission left counter check hits first

            $redis->set($key, 0);
            $log->clear();
            $emission = {};
            is $redis->get($key), 0, 'Counter back to 0';
            ok !BOM::User::Onfido::ready_for_authentication($test_client, {documents => ['S2', 'A', 'B']}), 'Could not acquired pending lock';
            cmp_deeply $emission, {}, 'No event emitted';
            is $redis->get($key), 0, 'Counter not increased';
            $log->contains_ok(qr/Unexpected Onfido request when pending flag is still alive/, 'warning log ok');    # this time the log is there
        };

        subtest 'no applicant' => sub {
            $applicant_id = undef;
            $log->clear();
            $emission = {};
            $redis->del($pending_key);
            ok !BOM::User::Onfido::ready_for_authentication($test_client, {documents => ['S2', 'A', 'B']}), 'Could not emit the event';
            cmp_deeply $emission, {}, 'No event emitted';
            is $redis->get($key), 0, 'Counter not increased';
            $log->contains_ok(qr/attempted ready_for_authentication emission without an applicant/, 'warning log ok');
        };

        $emission = {};
        $redis->del($pending_key);
        $applicant_id = 'X1';
        ok BOM::User::Onfido::ready_for_authentication(
            $test_client,
            {
                documents  => ['S3', 'X', 'Y'],
                staff_name => 'test'
            }
            ),
            'ready for auth';

        cmp_deeply $emission,
            {
            ready_for_authentication => {
                loginid      => $test_client->loginid,
                applicant_id => $applicant_id,
                documents    => ['S3', 'X', 'Y'],
                staff_name   => 'test',
            },
            },
            'Expected event emitted';

        $emit_mocker->unmock_all;
    };

    # Finish it

    $onfido_mock->unmock_all;
};

subtest 'applicant info' => sub {
    $test_client->first_name('Maria');
    $test_client->last_name('Juana');
    $test_client->date_of_birth('1969-04-20');
    $test_client->email('maria+juana@test.com');
    $test_client->save;
    cmp_deeply BOM::User::Onfido::applicant_info($test_client, 'gb'),
        +{
        first_name => 'Maria',
        last_name  => 'Juana',
        dob        => '1969-04-20',
        email      => 'maria+juana@test.com',
        address    => {
            street          => re('Ronald-Street \(\)lanes B\/O12'),
            state           => 'LA',
            town            => 'Beverly Hills',
            country         => 'GBR',
            postcode        => 232323,
            building_number => re('Ronald-Street \(\)lanes B\/O12')
        },
        location => {country_of_residence => 'PRY'},
        },
        'Expected applicant info';

    cmp_deeply BOM::User::Onfido::applicant_info($test_client),
        +{
        first_name => 'Maria',
        last_name  => 'Juana',
        dob        => '1969-04-20',
        email      => 'maria+juana@test.com',
        address    => {
            street          => re('Ronald-Street \(\)lanes B\/O12'),
            state           => 'LA',
            town            => 'Beverly Hills',
            country         => 'PRY',
            postcode        => 232323,
            building_number => re('Ronald-Street \(\)lanes B\/O12')
        },
        location => {country_of_residence => 'PRY'},
        },
        'Expected applicant info';
};

subtest 'PDF status' => sub {
    my $pending = BOM::User::Onfido::get_pending_pdf_checks(0);
    my $limit   = 10;

    cmp_deeply $pending, [], 'No limit, no checks';

    $pending = BOM::User::Onfido::get_pending_pdf_checks($limit);

    cmp_deeply $pending,
        [{
            id => $check->id,
        }
        ],
        'Got the check';

    # add more checks

    for my $i (1 .. $limit) {
        my $obj_check = $onfido->applicant_check(
            applicant_id => $app1->id,
            # We don't want Onfido to start emailing people
            suppress_form_emails => 1,
            # Used for reporting and filtering in the web interface
            tags => ['tag1', 'tag2'],
            # On v3 we need to specify the array of documents
            document_ids => [$doc1->id, $doc2->id],
            # On v3 we need to specify the report names
            report_names               => [qw/document facial_similarity_photo/],
            suppress_from_email        => 0,
            charge_applicant_for_check => 0,
        )->get;

        lives_ok { BOM::User::Onfido::store_onfido_check($app1->id, $obj_check); } 'Storing onfido check should pass';
    }

    BOM::User::Onfido::update_check_pdf_status($check->id, 'failed');

    $pending = BOM::User::Onfido::get_pending_pdf_checks(100);

    cmp_deeply $pending, [], 'No pending checks (status should be complete)';

    # change check status to complete

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    $dbic->run(
        fixup => sub {
            $_->do('UPDATE users.onfido_check set status=?', undef, 'complete');
        });

    ok((List::Util::none { $check->id eq $_->{id} } $pending->@*), 'Failed check is no longer here');

    $pending = BOM::User::Onfido::get_pending_pdf_checks(100);

    is scalar @$pending, $limit, '10 pending PDF checks';

    for my $chk ($pending->@*) {
        --$limit;

        BOM::User::Onfido::update_check_pdf_status($chk->{id}, 'completed');

        my $pending_after_update =
            BOM::User::Onfido::get_pending_pdf_checks(100);    # keep the param large to prove the number of pending documents is decreasing

        ok((List::Util::none { $chk->{id} eq $_->{id} } $pending_after_update->@*), 'Completed check is no longer here');

        is scalar @$pending_after_update, $limit, "$limit pending PDF checks";
    }
};

subtest 'is face similarity check required' => sub {
    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $cr_client->aml_risk_classification('low');

    ok !$cr_client->is_face_similarity_required, 'Face check not required for low risk CR accounts';

    $cr_client->aml_risk_classification('high');

    ok $cr_client->is_face_similarity_required, 'Face check required for high risk CR accounts';

    my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });

    ok $mf_client->is_face_similarity_required, 'Face check required for MF accounts';
};

subtest 'requires face similarity recheck - verified CR that became hr' => sub {
    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $cr_client->status->set('selfie_verified', 'test', 'test');

    ok !$cr_client->requires_selfie_recheck, 'Face recheck cannot be retriggered for accounts with already verified selfies';

    $cr_client->status->clear_selfie_verified();

    $cr_client->aml_risk_classification('low');

    ok !$cr_client->requires_selfie_recheck, 'Face recheck cannot be retriggered for low risk CR accounts';

    $cr_client->aml_risk_classification('high');

    ok !$cr_client->requires_selfie_recheck, 'Face recheck cannot be retriggered for high risk CR accounts without previous submission';

    my $mocked_cli = Test::MockModule->new(ref($cr_client));
    $mocked_cli->mock(
        'get_onfido_status',
        sub {
            return 'verified';
        });

    ok $cr_client->requires_selfie_recheck, 'Face recheck successfully retriggered for high risk CR accounts with previous submission';

    $mocked_cli->unmock_all;
};

subtest 'is onfido disallowed' => sub {
    my $user_cr = BOM::User->create(
        email    => 'onfido_disallowed@deriv.com',
        password => 'secret_pwd',
    );
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user_cr->id,
    });
    $user_cr->add_client($client_cr);

    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $latest_poi_by;
    $client_mock->mock(
        'latest_poi_by',
        sub {
            return 'idv';
        });

    my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
    $idv_mock->mock(
        'get_last_updated_document',
        sub {
            return {
                status          => 'verified',
                status_messages => '[]',
                document_type   => 'passport',
            };
        });

    my $lc_mock = Test::MockModule->new('LandingCompany');
    my $allowed_poi_providers;
    $lc_mock->mock(
        'allowed_poi_providers',
        sub {
            return $allowed_poi_providers;
        });

    my $short;

    $short                 = 'svg';
    $allowed_poi_providers = ['idv'];
    ok BOM::User::Onfido::is_onfido_disallowed({client => $client_cr, landing_company => $short}),
        'Disallowed if onfido not allowed for lc (provided as argument)';
    ok BOM::User::Onfido::is_onfido_disallowed({client => $client_cr}), 'Disallowed if onfido not allowed for lc (default from client)';
    $lc_mock->unmock_all;

    $client_cr->status->set('unwelcome', 'test', 'test');
    ok BOM::User::Onfido::is_onfido_disallowed({client => $client_cr}), 'Disallowed for unwelcome clients';
    $client_cr->status->clear_unwelcome();

    $client_cr->status->set('age_verification', 'test', 'test');
    $client_cr->aml_risk_classification('low');
    ok BOM::User::Onfido::is_onfido_disallowed({client => $client_cr}), 'Disallowed if client poi status is verified (idv verified)';
    ok BOM::User::Onfido::is_onfido_disallowed({client => $client_cr, landing_company => $short}),
        'Disallowed if client poi status is verified (idv verified)';

    $short = 'maltainvest';
    ok !BOM::User::Onfido::is_onfido_disallowed({client => $client_cr, landing_company => $short}),
        'Allowed if client poi status is not verified (idv verified but not allowed for maltainvest lc)';

    $client_cr->aml_risk_classification('high');
    ok !BOM::User::Onfido::is_onfido_disallowed({client => $client_cr}), 'Allowed if client poi status is not verified (idv verified but high risk)';

    $client_cr->status->clear_age_verification();
    ok !BOM::User::Onfido::is_onfido_disallowed({client => $client_cr}), 'Allowed for non age verified clients';

    $idv_mock->unmock_all;
    $client_mock->unmock_all;
};

subtest 'is available' => sub {
    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my $config_mock = Test::MockModule->new('BOM::Config::Onfido');

    $onfido_mock->mock(is_onfido_disallowed => 1);

    ok !BOM::User::Onfido::is_available({client => $test_client}), 'onfido is not available if onfido is disallowed';

    $onfido_mock->mock(is_onfido_disallowed => 0);
    $config_mock->mock(is_country_supported => 0);

    ok !BOM::User::Onfido::is_available({client => $test_client, country => 'aq'}), 'onfido is not available if country is not supported';

    $onfido_mock->mock(submissions_left => 1);

    ok BOM::User::Onfido::is_available({client => $test_client}), 'onfido is available if submissions left and country not provided';

    $config_mock->mock(is_country_supported => 1);
    $onfido_mock->mock(submissions_left     => 0);

    ok !BOM::User::Onfido::is_available({client => $test_client, country => 'co'}), 'onfido is not available if no submissions left';

    $onfido_mock->mock(submissions_left => 1);

    ok BOM::User::Onfido::is_available({client => $test_client, country => 'co'}), 'onfido is available if submissions left and country supported';

    $onfido_mock->unmock_all();
    $config_mock->unmock_all();
};

subtest 'suspended uploads' => sub {
    subtest 'add to the zset' => sub {
        my $redis = BOM::Config::Redis::redis_events();
        my $time  = time - 3600;

        set_absolute_time($time);

        BOM::User::Onfido::suspended_upload(10);

        my $zset = $redis->zrangebyscore(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, '-Inf', '+Inf', 'WITHSCORES');
        cmp_deeply $zset, [10, $time], 'Expected member added';

        set_absolute_time(2000 + $time);

        BOM::User::Onfido::suspended_upload(10);
        BOM::User::Onfido::suspended_upload(20);

        $zset = $redis->zrangebyscore(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, '-Inf', '+Inf', 'WITHSCORES');
        cmp_deeply $zset, [10, $time, 20, 2000 + $time], 'Expected member added';

        restore_time();
    };
};

subtest 'candidate documents' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email          => 'thecandidates@test.com',
        password       => "hello",
        email_verified => 1,
    );

    my $user_mock = Test::MockModule->new(ref($user));
    $user_mock->mock(
        'get_default_client',
        sub {
            return $client;
        });
    my $documents_mock = Test::MockModule->new(ref($client->documents));
    my $stash          = [];
    $documents_mock->mock(
        'stash',
        sub {
            my @args = @_;

            cmp_deeply [@args],
                [
                ignore(), 'uploaded', 'client',
                ['national_identity_card', 'identification_number_document', 'driving_licence', 'passport', 'selfie_with_id']
                ],
                'expected stash requested';

            return $stash;
        });

    subtest 'empty stash' => sub {
        $stash = [];

        is BOM::User::Onfido::candidate_documents($user), undef, 'Empty stash returns undef';
    };

    subtest 'only selfie' => sub {
        $stash = [
            build_document({
                    document_type   => 'selfie_with_id',
                    issuing_country => 'br',
                })];

        is BOM::User::Onfido::candidate_documents($user), undef, 'No valid candidates return undef';
    };

    my $two_sided = [qw/national_identity_card driving_licence identification_number_document/];
    my $sides     = [qw/front back/];

    subtest 'two sided documents' => sub {
        subtest 'only one side' => sub {
            for my $document_type ($two_sided->@*) {
                subtest $document_type => sub {
                    $stash = [
                        build_document({
                                document_type   => 'selfie_with_id',
                                issuing_country => 'br',
                                file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                                id              => 1,
                            }
                        ),
                        build_document({
                                document_type   => $document_type,
                                issuing_country => 'br',
                                file_name       => "CR1.$document_type.2_front.jpg",
                                id              => 2,
                            }
                        ),
                    ];

                    is BOM::User::Onfido::candidate_documents($user), undef, 'No valid candidates return undef';

                    $stash = [
                        build_document({
                                document_type   => 'selfie_with_id',
                                issuing_country => 'br',
                                file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                                id              => 1,
                            }
                        ),
                        build_document({
                                document_type   => $document_type,
                                issuing_country => 'br',
                                file_name       => "CR1.$document_type.2_front.jpg",
                                id              => 2,
                            }
                        ),
                        build_document({
                                document_type   => $document_type,
                                issuing_country => 'br',
                                file_name       => "CR1.$document_type.3_front.jpg",
                                id              => 4,
                            }
                        ),
                        build_document({
                                document_type   => $document_type,
                                issuing_country => 'br',
                                file_name       => "CR1.$document_type.4_front.jpg",
                                id              => 4,
                            }
                        ),
                        build_document({
                                document_type   => $document_type,
                                issuing_country => 'br',
                                file_name       => "CR1.$document_type.5_front.jpg",
                                id              => 5,
                            }
                        ),
                    ];

                    is BOM::User::Onfido::candidate_documents($user), undef, 'No valid candidates return undef';
                };
            }

            subtest 'mixings' => sub {
                my $i = 1;

                for my $side ($sides->@*) {
                    $stash = [
                        build_document({
                                document_type   => 'selfie_with_id',
                                issuing_country => 'br',
                                file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                                id              => 1,
                            }
                        ),
                        map {
                            $i++;

                            build_document({
                                    document_type   => $_,
                                    issuing_country => 'br',
                                    file_name       => "CR1.$_.$i\_$side.jpg",
                                    id              => $i,
                                })
                        } $two_sided->@*,
                    ];

                    is BOM::User::Onfido::candidate_documents($user), undef, 'No valid candidates return undef';
                }

                my @sides = $sides->@*;
                push @sides, 'back';

                $stash = [
                    build_document({
                            document_type   => 'selfie_with_id',
                            issuing_country => 'br',
                            file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                            id              => 1,
                        }
                    ),
                    map {
                        my $side = shift @sides;
                        $i++;

                        build_document({
                                document_type   => $_,
                                issuing_country => 'br',
                                file_name       => "CR1.$_.$i\_$side.jpg",
                                id              => $i,
                            })
                    } $two_sided->@*,
                ];

                @sides = reverse $sides->@*;
                push @sides, 'back';

                $stash = [
                    build_document({
                            document_type   => 'selfie_with_id',
                            issuing_country => 'br',
                            file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                            id              => 1,
                        }
                    ),
                    map {
                        my $side = shift @sides;
                        $i++;

                        build_document({
                                document_type   => $_,
                                issuing_country => 'br',
                                file_name       => "CR1.$_.$i\_$side.jpg",
                                id              => $i,
                            })
                    } $two_sided->@*,
                ];

                is BOM::User::Onfido::candidate_documents($user), undef, 'No valid candidates return undef';

                # some permutations

                for my $document_type ($two_sided->@*) {
                    for my $side ($sides->@*) {
                        $stash = [
                            build_document({
                                    document_type   => 'selfie_with_id',
                                    issuing_country => 'br',
                                    file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                                    id              => 1,
                                }
                            ),
                            build_document({
                                    document_type   => $document_type,
                                    issuing_country => 'br',
                                    file_name       => "CR1.$document_type.2_$side.jpg",
                                    id              => 2,
                                }
                            ),
                            build_document({
                                    document_type   => $document_type,
                                    issuing_country => 'br',
                                    file_name       => "CR1.$document_type.3_$side.jpg",
                                    id              => 3,
                                }
                            ),
                        ];

                        is BOM::User::Onfido::candidate_documents($user), undef, 'No valid candidates return undef';
                    }
                }
            };

            subtest 'valid candidates' => sub {
                for my $document_type ($two_sided->@*) {
                    subtest $document_type => sub {
                        my $i = 1;

                        $stash = [
                            build_document({
                                    document_type   => 'selfie_with_id',
                                    issuing_country => 'br',
                                    file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                                    id              => 1,
                                }
                            ),
                            map {
                                $i++;

                                build_document({
                                        document_type   => $document_type,
                                        issuing_country => 'br',
                                        file_name       => "CR1.$document_type.$i\_$_.jpg",
                                        id              => $i,
                                    })
                            } $sides->@*,
                        ];

                        my @stash = $stash->@*;

                        cmp_deeply BOM::User::Onfido::candidate_documents($user),
                            {
                            selfie    => shift @stash,
                            documents => [reverse @stash],
                            },
                            'Expected candidates returned';

                        $i = 3;

                        $stash = [
                            build_document({
                                    document_type   => 'selfie_with_id',
                                    issuing_country => 'br',
                                    file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                                    id              => 1,
                                }
                            ),
                            map {
                                $i--;

                                build_document({
                                        document_type   => $document_type,
                                        issuing_country => 'br',
                                        file_name       => "CR1.$document_type.$i\_$_.jpg",
                                        id              => $i,
                                    })
                            } $sides->@*,
                        ];

                        @stash = $stash->@*;

                        cmp_deeply BOM::User::Onfido::candidate_documents($user),
                            {
                            selfie    => shift @stash,
                            documents => [@stash],
                            },
                            'Expected candidates returned';
                    }
                }
            };
        };
    };

    my $one_sided = [qw/passport/];

    subtest 'one sided documents' => sub {
        for my $document_type ($one_sided->@*) {
            # generally speaking, we don't care about the side for passports, this will be `front` always
            for my $side ($sides->@*) {
                subtest $document_type => sub {
                    $stash = [
                        build_document({
                                document_type   => 'selfie_with_id',
                                issuing_country => 'br',
                                file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                                id              => 1,
                            }
                        ),
                        build_document({
                                document_type   => $document_type,
                                issuing_country => 'br',
                                file_name       => "CR1.$document_type.2_$side.jpg",
                                id              => 2,
                            }
                        ),
                    ];

                    my @stash = $stash->@*;

                    cmp_deeply BOM::User::Onfido::candidate_documents($user),
                        {
                        selfie    => shift @stash,
                        documents => [@stash],
                        },
                        'Expected candidates returned';
                }
            }
        }
    };

    subtest 'ties' => sub {
        $stash = [
            build_document({
                    document_type   => 'selfie_with_id',
                    issuing_country => 'br',
                    file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                    id              => 1,
                }
            ),
            build_document({
                    document_type   => 'national_identity_card',
                    issuing_country => 'br',
                    file_name       => "CR1.national_identity_card.4_front.jpg",
                    id              => 4,
                }
            ),
            build_document({
                    document_type   => 'national_identity_card',
                    issuing_country => 'br',
                    file_name       => "CR1.national_identity_card.3_back.jpg",
                    id              => 3,
                }
            ),
            build_document({
                    document_type   => 'passport',
                    issuing_country => 'br',
                    file_name       => "CR1.passport.10_front.jpg",
                    id              => 10,
                }
            ),
        ];

        my @stash = $stash->@*;

        cmp_deeply BOM::User::Onfido::candidate_documents($user),
            {
            selfie    => shift @stash,
            documents => [$stash[2]],
            },
            'Expected candidates returned (passport)';

        $stash = [
            build_document({
                    document_type   => 'selfie_with_id',
                    issuing_country => 'br',
                    file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                    id              => 1,
                }
            ),
            build_document({
                    document_type   => 'national_identity_card',
                    issuing_country => 'br',
                    file_name       => "CR1.national_identity_card.4_front.jpg",
                    id              => 4,
                }
            ),
            build_document({
                    document_type   => 'national_identity_card',
                    issuing_country => 'br',
                    file_name       => "CR1.national_identity_card.3_back.jpg",
                    id              => 3,
                }
            ),
            build_document({
                    document_type   => 'passport',
                    issuing_country => 'br',
                    file_name       => "CR1.passport.10_front.jpg",
                    id              => 2,
                }
            ),
        ];

        @stash = $stash->@*;

        cmp_deeply BOM::User::Onfido::candidate_documents($user),
            {
            selfie    => shift @stash,
            documents => [$stash[0], $stash[1]],
            },
            'Expected candidates returned (national_identity_card)';
    };

    $documents_mock->unmock_all;
    $user_mock->unmock_all;
};

sub build_document {
    my $args = shift;

    return (bless $args, 'BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument');
}
