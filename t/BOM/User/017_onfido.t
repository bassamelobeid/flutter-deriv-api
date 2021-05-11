use strict;
use warnings;
use Test::More tests => 11;
use Test::Exception;
use Test::NoWarnings;
use Test::Warn;
use Test::Warnings;
use Test::Deep;
use Test::MockModule;
use JSON::MaybeUTF8 qw(encode_json_utf8);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::OnfidoMock;

use BOM::User::Onfido;
use WebService::Async::Onfido;

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
    throws_ok {
        warning_like { BOM::User::Onfido::get_all_user_onfido_applicant("hello"); } qr/invalid input syntax for integer/, 'there is warn'
    }
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

subtest 'store & get onfido document' => sub {
    my $doc1 = $onfido->document_upload(
        applicant_id    => $app1->id,
        filename        => "document1.png",
        type            => 'passport',
        issuing_country => 'China',
        data            => 'This is passport',
        side            => 'front',
    )->get;
    my $doc2 = $onfido->document_upload(
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

my $check;
subtest 'store & update & fetch check ' => sub {
    $check = $onfido->applicant_check(
        applicant_id => $app1->id,
        type         => 'standard',
        reports      => [
            {name => 'document'},
            {
                name    => 'facial_similarity',
                variant => 'standard'
            }
        ],
        tags                       => ['tag1', 'tag2'],
        suppress_from_email        => 0,
        async                      => 1,
        charge_applicant_for_check => 0,
    )->get;
    $check->{status} = 'in_progress';
    lives_ok { BOM::User::Onfido::store_onfido_check($app1->id, $check); } 'Storing onfido check should pass';
    my $result;
    lives_ok { $result = BOM::User::Onfido::get_latest_onfido_check($test_client->binary_user_id); } 'get latest onfido check should pass';
    is($result->{id},     $check->id,    'get latest onfido check result ok');
    is($result->{status}, 'in_progress', 'the status of check is in_progress');
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
    is BOM::User::Onfido::limit_per_user,   3,       'The allowed submissions counter is 3';
    is BOM::User::Onfido::timeout_per_user, 1296000, '15 days to reset the counter';
};

subtest 'submissions left per user' => sub {
    my $limit = BOM::User::Onfido::limit_per_user();
    is BOM::User::Onfido::submissions_left($test_client), $limit, 'The client has all the submissions left';

    my $submissions_used = 0;
    my $redis_mock       = Test::MockModule->new('RedisDB');
    $redis_mock->mock(
        'get',
        sub {
            return $submissions_used;
        });

    foreach my $i (1 .. 3) {
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
    $onfido_mock->mock(
        'get_latest_onfido_check',
        sub {
            return {
                id     => 'TESTING',
                status => 'complete',
                result => 'consider',
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

    # Perform the test

    subtest 'Breakdown coverage' => sub {
        foreach my $case ($cases->@*) {
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
        }
    };

    # Selfie case

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

        $poi_name_mismatch = 1;
        $reasons           = BOM::User::Onfido::get_rules_reasons($test_client);
        cmp_deeply($reasons, set(['data_comparison.first_name']->@*), 'Name mismatch reported');

        $poi_name_mismatch = 0;
        $reasons           = BOM::User::Onfido::get_rules_reasons($test_client);
        cmp_deeply($reasons, set([]->@*), 'No reason reported');

        $status_mock->unmock_all;
    };

    # Finish it

    $onfido_mock->unmock_all;
};
