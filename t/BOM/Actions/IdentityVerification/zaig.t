use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Fatal;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::User::IdentityVerification;
use BOM::User;
use BOM::Event::Process;
use BOM::Test::Email;

use Future;
use Future::Exception;
use HTTP::Response;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use URL::Encode qw(url_decode);

# Don't use microservice
my $mock_idv_event_action = Test::MockModule->new('BOM::Event::Actions::Client::IdentityVerification');
$mock_idv_event_action->mock('_is_microservice_available', 0);

my $track_mock = Test::MockModule->new('BOM::Event::Services::Track');
$track_mock->mock(
    'track_event',
    sub {
        return 1;
    });
my $idv_event_handler = \&BOM::Event::Actions::Client::IdentityVerification::verify_identity;

# All the http requests are mocked, so there isn't network usage in this test.

subtest 'verify' => sub {
    my ($response, $request);
    my $http_mock = Test::MockModule->new('Net::Async::HTTP');
    my $http      = {
        code      => 200,
        content   => {},
        exception => 0,
    };

    my $user_stash      = {};
    my $doc_check_stash = {};
    my $user;
    my $client;
    my $idv;
    my $submissions_left;
    my $statuses        = {};
    my $analysis_output = {};
    my $reset_to_zero;

    my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
    $idv_mock->mock(
        'submissions_left',
        sub {
            return $submissions_left;
        });
    $idv_mock->mock(
        'reset_to_zero_left_submissions',
        sub {
            $reset_to_zero = 1;
            return 1;
        });

    $http_mock->mock(
        'do_request',
        sub {
            my (undef, %args) = @_;
            $response = undef;
            $request  = undef;

            die 'Awful exception' unless defined $http;

            if ($args{method} eq 'GET') {
                my @uri_chunks = split '/', $args{uri};
                my $id = url_decode(pop @uri_chunks);

                $http->{get}->{data}->{analysis_status}        = $statuses->{$id};
                $http->{get}->{data}->{analysis_status_events} = [{
                        analysis_output => $analysis_output->{$id},
                    }];

                # the get request could fail for whatever reason, that should be tested too
                if ($http->{get}->{exception}) {
                    if (ref($http->{get}->{exception}) eq 'HASH') {
                        $response = HTTP::Response->new(404);
                        $response->content(eval { encode_json_utf8($http->{get}->{exception}) });
                        Future::Exception->throw('not found', 'http', $response);
                    } else {
                        die 'Awful exception';
                    }
                } else {
                    # this may be useful to test name mismatch and underage scenarios
                    $response = HTTP::Response->new(200);
                    $response->content(eval { encode_json_utf8($http->{get}->{data}) });

                    return Future->done($response);
                }
            } else {
                $response = HTTP::Response->new($http->{code});
                $http->{content}->{id} = $user->id;

                my $req_body = decode_json_utf8 $args{content};

                # The sandbox `ambiente` offers the following status mapping based on the first digit of the document given:
                # taken from https://docs.zaig.com.br/onboarding/#ambientes
                # 0 - automatically_approved (e.g. 039.471.658-20)
                # 1 - in_manual_analysis (e.g. 124.381.111-00)
                # 2 - in_manual_analysis (e.g. 297.612.306-35)
                # 3 - automatically_reproved (e.g. 331.075.499-59)
                # 4 - pending (e.g. 419.574.338-92)

                # Although, take into account, for our company setup in production
                # the only statuses returned will be automatically_approved or automatically_reproved.

                if ($http->{like_sandbox}) {
                    $http->{content}->{analysis_status} = 'automatically_approved' if $req_body->{document_number} =~ /^0/;
                    $http->{content}->{analysis_status} = 'in_manual_analysis'     if $req_body->{document_number} =~ /^1/;
                    $http->{content}->{analysis_status} = 'in_manual_analysis'     if $req_body->{document_number} =~ /^2/;
                    $http->{content}->{analysis_status} = 'automatically_reproved' if $req_body->{document_number} =~ /^3/;
                    $http->{content}->{analysis_status} = 'pending'                if $req_body->{document_number} =~ /^4/;
                }

                $response->content(eval { encode_json_utf8($http->{content}) });
                $request                            = $args{content};
                $statuses->{$req_body->{id}}        = $http->{content}->{analysis_status};
                $analysis_output->{$req_body->{id}} = $http->{content}->{analysis_output} // {};

                Future::Exception->throw('mocked fail', 'http', $response) if $http->{exception};

                return Future->done($response);
            }
        });

    my $tests = [{
            title    => 'Non http exception',
            document => {
                issuing_country => 'br',
                number          => '3434233',
                type            => 'cpf',
            },
            email  => 'user1@idv.com',
            http   => undef,
            result => {
                status   => 'failed',
                messages => ['An unknown error happened.'],
            },
            submissions_left => 1,
        },
        {
            title    => 'Http exception with a title',
            document => {
                issuing_country => 'br',
                number          => '1122334455',
                type            => 'cpf',
            },
            email => 'user2@idv.com',
            http  => {
                code      => 403,
                exception => 1,
                content   => {title => 'Invalid ApiKey'}
            },
            result => {
                status   => 'failed',
                messages => ['Zaig respond an error to our request with title: Invalid ApiKey, description: UNKNOWN'],
            },
            submissions_left => 1,
        },
        {
            title    => 'Http exception with a description',
            document => {
                issuing_country => 'br',
                number          => '1122334455',
                type            => 'cpf',
            },
            email => 'user2@idv.com',
            http  => {
                code      => 403,
                exception => 1,
                content   => {description => 'Something was wrong'}
            },
            result => {
                status   => 'failed',
                messages => ['Zaig respond an error to our request with title: UNKNOWN, description: Something was wrong'],
            },
            submissions_left => 1,
        },
        {
            title    => 'No resubmissions left',
            document => {
                issuing_country => 'br',
                number          => '1122334455',
                type            => 'cpf',
            },
            email => 'user2@idv.com',
            http  => {
                code      => 403,
                exception => 1,
                content   => {
                    description => 'Something was badly wrong',
                    title       => 'busted'
                }
            },
            result => {
                status    => undef,                                                           # this just breaks the subtest, nothing else to check
                exception => 'No submissions left, IDV request has ignored for loginid: .*'
            },
            submissions_left => 0,
        },
        {
            title    => 'Http exception with empty body',
            document => {
                issuing_country => 'br',
                number          => '1122334455',
                type            => 'cpf',
            },
            email => 'user3@idv.com',
            http  => {
                code      => 403,
                exception => 1,
                content   => {},
            },
            result => {
                status   => 'failed',
                messages => ['Zaig respond an error to our request with title: UNKNOWN, description: UNKNOWN'],
            },
            submissions_left => 1,
        },
        {
            title    => 'Conflict',
            document => {
                issuing_country => 'br',
                number          => '1122334455',
                type            => 'cpf',
            },
            email => 'user344@idv.com',
            http  => {
                code      => 409,
                exception => 1,
                content   => {title => 'Duplicated external_id'},
            },
            result => {
                status   => 'failed',
                messages => ['EMPTY_STATUS'],
            },
            submissions_left => 1,
        },
        {
            title    => 'Bad Request',
            document => {
                issuing_country => 'br',
                number          => '1122334455',
                type            => 'cpf',
            },
            email => 'user34444@idv.com',
            http  => {
                code      => 400,
                exception => 1,
                content   => {title => 'Invalid request'},
            },
            result => {
                status   => 'failed',
                messages => ['DOCUMENT_REJECTED'],
            },
            submissions_left    => 1,
            submissions_to_zero => 1,
        },
        {
            title    => 'Http exception with null body',
            document => {
                issuing_country => 'br',
                number          => '1122334455',
                type            => 'cpf',
            },
            email => 'user3@idv.com',
            http  => {
                code      => 403,
                exception => 1,
                content   => undef,
            },
            result => {
                status   => 'failed',
                messages => ['Zaig respond an error to our request with title: UNKNOWN, description: UNKNOWN'],
            },
            submissions_left => 1,
        },
        # enough exceptions let's do valid sandbox-like requests
        {
            title    => 'Sandbox-like request first digit: 0',
            document => {
                issuing_country => 'br',
                number          => '039.471.658-20',
                type            => 'cpf',
            },
            email => 'user4@idv.com',
            http  => {
                like_sandbox => 1,
                get          => {
                    exception => undef,
                },
                content => {
                    analysis_output => {
                        basic_data => {
                            name => {
                                result      => 'positive',
                                description => 'name_match',
                            },
                            birthdate => {
                                result      => 'positive',
                                description => 'birthdate_match'
                            }}}}
            },
            result => {
                status    => 'verified',
                messages  => undef,
                exception => undef,
            },
            submissions_left => 1,
        },
        {
            title    => 'Sandbox-like request first digit: 1',
            document => {
                issuing_country => 'br',
                number          => '124.381.111-00',
                type            => 'cpf',
            },
            email => 'user5@idv.com',
            http  => {
                like_sandbox => 1,
                get          => {
                    exception => undef,
                },
            },
            result => {
                status   => 'failed',
                messages => ['EMPTY_STATUS'],
            },
            submissions_left => 1,
        },
        {
            title    => 'Sandbox-like request first digit: 2',
            document => {
                issuing_country => 'br',
                number          => '297.612.306-35',
                type            => 'cpf',
            },
            email => 'user6@idv.com',
            http  => {
                like_sandbox => 1,
                get          => {
                    exception => undef,
                },
            },
            result => {
                status   => 'failed',
                messages => ['EMPTY_STATUS'],
            },
            submissions_left => 1,
        },
        {
            title    => 'Sandbox-like request first digit: 3',
            document => {
                issuing_country => 'br',
                number          => '331.075.499-59',
                type            => 'cpf',
            },
            email => 'user7@idv.com',
            http  => {
                like_sandbox => 1,
                get          => {
                    exception => undef,
                },
            },
            result => {
                status   => 'refuted',
                messages => ['EMPTY_STATUS'],
            },
            submissions_left    => 2,
            submissions_to_zero => 1,
        },
        {
            title    => 'Sandbox-like request first digit: 4',
            document => {
                issuing_country => 'br',
                number          => '419.574.338-92',
                type            => 'cpf',
            },
            email => 'user8@idv.com',
            http  => {
                like_sandbox => 1,
                get          => {
                    exception => undef,
                },
            },
            result => {
                status   => 'failed',
                messages => ['EMPTY_STATUS'],
            },
            submissions_left => 1,
        },
        # More exceptions
        {
            title    => 'Exception on data retrieval',
            document => {
                issuing_country => 'br',
                number          => '039.471.658-20',
                type            => 'cpf',
            },
            email => 'user9@idv.com',
            http  => {
                like_sandbox => 1,
                get          => {
                    exception => 1,
                },
            },
            result => {
                status   => 'failed',
                messages => ['An unknown error happened.'],
            },
            submissions_left => 1,
        },
        {
            title    => 'Http exception on data retrieval',
            document => {
                issuing_country => 'br',
                number          => '039.471.658-20',
                type            => 'cpf',
            },
            email => 'user10@idv.com',
            http  => {
                like_sandbox => 1,
                get          => {
                    exception => {
                        title       => 'Register not found',
                        description => 'No such person',
                    },
                },
            },
            result => {
                status   => 'failed',
                messages => ['Zaig respond an error to our request with title: Register not found, description: No such person',],
            },
            submissions_left => 1,
        },
        # invalid status
        {
            title    => 'Invalid status from Zaig',
            document => {
                issuing_country => 'br',
                number          => '419.574.338-92',
                type            => 'cpf',
            },
            email => 'user11@idv.com',
            http  => {
                like_sandbox => 0,
                content      => {
                    analysis_status => 'disapproved',
                },
                get => {
                    exception => undef,
                },
            },
            result => {
                status   => 'failed',
                messages => ['UNAVAILABLE_STATUS'],
            },
            submissions_left => 1,
        },
        # Analysis Output
        {
            title    => 'Name Mismatch',
            document => {
                issuing_country => 'br',
                number          => '419.574.338-92',
                type            => 'cpf',
            },
            email => 'user12@idv.com',
            http  => {
                like_sandbox => 0,
                content      => {
                    analysis_status => 'automatically_reproved',
                    analysis_output => {
                        basic_data => {
                            name => {
                                result      => 'negative',
                                description => 'name_mismatch',
                            },
                            birthdate => {
                                result      => 'positive',
                                description => 'birthdate_match'
                            }}}
                },
                get => {
                    exception => undef,
                },
            },
            result => {
                status   => 'refuted',
                messages => ['NAME_MISMATCH'],
            },
            submissions_left    => 1,
            submissions_to_zero => 1,
        },
        {
            title    => 'Birthday Mismatch',
            document => {
                issuing_country => 'br',
                number          => '419.574.338-92',
                type            => 'cpf',
            },
            email => 'user12@idv.com',
            http  => {
                like_sandbox => 0,
                content      => {
                    analysis_status => 'automatically_reproved',
                    analysis_output => {
                        basic_data => {
                            name => {
                                result      => 'positive',
                                description => 'name_match',
                            },
                            birthdate => {
                                result      => 'negative',
                                description => 'birthdate_mismatch'
                            }}}
                },
                get => {
                    exception => undef,
                },
            },
            result => {
                status   => 'refuted',
                messages => ['DOB_MISMATCH'],
            },
            submissions_left    => 1,
            submissions_to_zero => 1,
        },
        {
            title    => 'doc not found',
            document => {
                issuing_country => 'br',
                number          => '419.574.338-92',
                type            => 'cpf',
            },
            email => 'user12211@idv.com',
            http  => {
                like_sandbox => 0,
                content      => {
                    analysis_status => 'automatically_reproved',
                    analysis_output => {reason => 'document_not_found'},
                },
                get => {
                    exception => undef,
                },
            },
            result => {
                status   => 'refuted',
                messages => ['DOCUMENT_REJECTED'],
            },
            submissions_left    => 1,
            submissions_to_zero => 1,
        },
        {
            title    => 'Underage detected',
            document => {
                issuing_country => 'br',
                number          => '419.574.338-92',
                type            => 'cpf',
            },
            email => 'user1224444@idv.com',
            http  => {
                like_sandbox => 0,
                content      => {
                    analysis_status => 'automatically_reproved',
                    analysis_output => {reason => 'underage_user'},
                },
                get => {
                    exception => undef,
                },
            },
            result => {
                status   => 'refuted',
                messages => ['UNDERAGE'],
            },
            submissions_left    => 1,
            submissions_to_zero => 1,
        },
        {
            title    => 'Underage detected 2',
            document => {
                issuing_country => 'br',
                number          => '419.574.338-92',
                type            => 'cpf',
            },
            email => 'user12244444@idv.com',
            http  => {
                like_sandbox => 0,
                content      => {
                    analysis_status => 'automatically_reproved',
                    analysis_output => {reason => 'underage_verified_on_receita_federal'},
                },
                get => {
                    exception => undef,
                },
            },
            result => {
                status   => 'refuted',
                messages => ['UNDERAGE'],
            },
            submissions_left    => 1,
            submissions_to_zero => 1,
        },
        {
            title    => 'Deceased person detected',
            document => {
                issuing_country => 'br',
                number          => '126.043.057-0',
                type            => 'cpf',
            },
            email => 'userdeceased@idv.com',
            http  => {
                like_sandbox => 0,
                content      => {
                    analysis_status => 'automatically_reproved',
                    analysis_output => {reason => 'deceased_person'},
                },
                get => {
                    exception => undef,
                },
            },
            result => {
                status   => 'refuted',
                messages => ['DECEASED'],
            },
            submissions_left    => 1,
            submissions_to_zero => 1,
        },
    ];

    for my $test ($tests->@*) {
        my ($title, $doc_data, $email, $mock_http, $result, $left, $submissions_to_zero, $date_of_birth) =
            @{$test}{qw/title document email http result submissions_left submissions_to_zero date_of_birth/};
        $http             = $mock_http;
        $submissions_left = $left;
        $reset_to_zero    = undef;

        subtest $title => sub {
            $user = $user_stash->{$email} // BOM::User->create(
                email    => $email,
                password => 'TestMe1234',
            );

            $user_stash->{$email} = $user;

            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code    => 'CR',
                email          => $email,
                binary_user_id => $user->id,
            });

            if ($date_of_birth) {
                $client->date_of_birth($date_of_birth);
                $client->save;
            }

            $user->add_client($client);

            $idv = BOM::User::IdentityVerification->new(user_id => $user->id);

            my $document = $idv->add_document($doc_data);

            my $exception = exception {
                $idv_event_handler->({
                        loginid => $client->loginid,
                    }
                    )->get
            };

            if (my $e = $result->{exception}) {
                like $exception, qr/\b$e\b/, 'Expected exception thrown';
            } else {
                ok !$exception, 'The event made it alive';
            }

            if (my $status = $result->{status}) {
                my $doc = $idv->get_last_updated_document();
                is $doc->{status}, $result->{status}, 'Expected doc status';
                cmp_bag decode_json_utf8($doc->{status_messages} // '[]'), $result->{messages} // [], 'Expected doc messages';

                my $msgs = $result->{messages} // [];

                if (grep { $_ eq 'NAME_MISMATCH' } $msgs->@*) {
                    ok $client->status->poi_name_mismatch, 'POI name mismatch is set';
                }

                if (grep { $_ eq 'UNDERAGE' } $msgs->@*) {
                    ok $client->status->disabled, 'Disabled due to underage detection';
                }

                if ($status eq 'verified') {
                    ok $client->status->age_verification, 'POI status set';
                    ok !$client->status->poi_name_mismatch, 'POI name mismatch is not set';
                }

                if ($submissions_to_zero) {
                    ok $reset_to_zero, 'Submissions reset to zero';
                } else {
                    ok !$reset_to_zero, 'Submissions did not reset to zero';
                }
            }
        };
    }

    $http_mock->unmock_all;
};

subtest 'shrinker' => sub {
    my $payload = {
        analysis_status        => 1,
        analysis_status_events => 2,
        name                   => 3,
        birthdate              => 4,
        natural_person_key     => 5,
        garbage                => 6,
        trash                  => 7,
    };

    cmp_deeply BOM::Event::Actions::Client::IdentityVerification::_shrink_zaig_response($payload),
        {%$payload{qw/analysis_status analysis_status_events name birthdate natural_person_key/}}, 'Expected shrinked response';
};

$track_mock->unmock_all;

done_testing();
