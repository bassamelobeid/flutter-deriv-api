use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Script::PictureCollector;
use BOM::User::Client;
use BOM::User;

use Future::AsyncAwait;
use File::Path;
use File::Find;
use Future;

my $total_files = 0;

subtest 'The Picture Collector script' => sub {
    my $exception;

    my $args = {
        dryrun => 1,
    };

    subtest 'Input validation' => sub {
        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok $exception =~ /country is mandatory/, 'Country is mandatory';

        $args->{country} = 'br';

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok $exception =~ /broker is mandatory/, 'Broker is mandatory';

        $args->{broker} = 'CR';

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok $exception =~ /total is mandatory/, 'total is mandatory';

        $args->{total} = 'garbage';

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok $exception =~ /total should be numeric/, 'total should be numeric';

        $args->{total} = '10.0000001';

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok $exception =~ /document type is mandatory/, 'Document type is mandatory';

        $args->{document_type} = 'passport';

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok $exception =~ /status is mandatory/, 'Status is mandatory';

        $args->{status} = 'verified';

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok $exception =~ /bundle is not a directory/, 'Bundle is not a directory';

        my $folder = '/tmp/kyc_pictures_' . time;

        mkdir $folder;

        chmod 0000, $folder;

        $args->{bundle} = $folder;

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok $exception =~ /bundle is not writable/, 'Bundle is not writable';

        chmod 0755, $folder;

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok !$exception, 'Input is OK';

        $args->{page_size} = 'WHATIF';

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok $exception =~ /page size should be numeric/, 'page size should be numeric';

        $args->{page_size} = '1.23456789e+001';

        $exception = exception { ok !BOM::User::Script::PictureCollector->run($args)->get(); };

        ok !$exception, 'Input is OK';

        is $args->{page_size}, 12, 'Expected cast to int';
        is $args->{total},     10, 'Expected cast to int';

        rmtree($folder);
    };

    $args->{dryrun} = 0;

    subtest 'no documents uploaded' => sub {
        my $folder = '/tmp/kyc_pictures_' . time;

        mkdir $folder;

        chmod 0755, $folder;

        my $mock = Test::MockModule->new('BOM::User::Script::PictureCollector');
        my $db_hits;

        $mock->mock(
            'documents',
            sub {
                $db_hits++;

                return $mock->original('documents')->(@_);
            });

        for my $side (undef, 'front', 'back') {
            $args->{side} = $side;

            my $title = $side // 'no side';

            subtest "querying $title" => sub {
                $db_hits   = 0;
                $exception = exception { cmp_deeply(BOM::User::Script::PictureCollector->run($args)->get(), +{}); };
                ok !$exception, 'No exception observed';
                is $db_hits, 1, '1 DB hit';
            };
        }

        $mock->unmock_all;
        rmtree($folder);
    };

    subtest 'documents table has info' => sub {
        my $folder = '/tmp/kyc_pictures_' . time;
        my $blob;

        mkdir $folder;

        chmod 0755, $folder;

        my $mock = Test::MockModule->new('BOM::User::Script::PictureCollector');
        my $db_hits;
        $mock->mock(
            'documents',
            sub {
                $db_hits++;

                return $mock->original('documents')->(@_);
            });
        my $download_hits;
        $mock->mock(
            'download',
            sub {
                $download_hits++;
                return Future->done($blob);
            });

        seed(
            15,
            {
                country => 'br',
                side    => 'front',
                type    => 'driving_license',
                status  => 'verified',
            });

        seed(
            20,
            {
                country => 'br',
                side    => 'back',
                type    => 'driving_license',
                status  => 'verified',
            });

        seed(
            13,
            {
                country => 'co',
                type    => 'passport',
                status  => 'verified',
            });

        seed(
            2,
            {
                country => 'br',
                type    => 'passport',
                status  => 'verified',
            });

        seed(
            7,
            {
                side    => 'back',
                country => 'co',
                type    => 'driving_license',
                status  => 'verified',
            });

        seed(
            7,
            {
                side    => 'back',
                country => 'co',
                type    => 'driving_license',
                status  => 'rejected',
            });

        seed(
            11,
            {
                side    => 'front',
                country => 'ar',
                type    => 'driving_license',
                status  => 'verified',
            });

        my $tests = [{
                query => {
                    issuing_country => 'br',
                    total           => 7,
                    document_type   => 'driving_license',
                    status          => 'verified',
                },
                expected => {
                    db_hits       => 1,
                    files         => 7,
                    download_hits => 7,
                },
            },
            {
                query => {
                    issuing_country => 'br',
                    total           => 7,
                    side            => 'back',
                    document_type   => 'driving_license',
                    status          => 'verified'
                },
                expected => {
                    db_hits       => 1,
                    files         => 7,
                    download_hits => 7,
                },
            },
            {
                query => {
                    issuing_country => 'br',
                    total           => 8,
                    page_size       => 2,
                    document_type   => 'driving_license',
                    status          => 'verified'
                },
                expected => {
                    db_hits       => 4,
                    files         => 8,
                    download_hits => 1,
                },
            },
            {
                query => {
                    issuing_country => 'br',
                    total           => 9,
                    page_size       => 2,
                    document_type   => 'driving_license',
                    status          => 'verified'
                },
                expected => {
                    db_hits       => 5,
                    files         => 9,
                    download_hits => 1,
                },
            },
            {
                query => {
                    issuing_country => 'br',
                    total           => 13,
                    side            => 'back',
                    page_size       => 4,
                    document_type   => 'driving_license',
                    status          => 'verified'
                },
                expected => {
                    db_hits       => 4,
                    files         => 13,
                    download_hits => 6,
                },
            },
            {
                query => {
                    issuing_country => 'br',
                    total           => 13,
                    side            => 'back',
                    page_size       => 4,
                    document_type   => 'driving_license',
                    status          => 'rejected'
                },
                expected => {
                    db_hits       => 1,
                    files         => 0,
                    download_hits => 0,
                },
            },
            {
                query => {
                    issuing_country => 'br',
                    total           => 9,
                    side            => 'back',
                    page_size       => 1,
                    document_type   => 'passport',
                    status          => 'rejected'
                },
                expected => {
                    db_hits       => 1,
                    files         => 0,
                    download_hits => 0,
                },
            },
            {
                query => {
                    issuing_country => 'br',
                    total           => 9,
                    side            => 'back',
                    page_size       => 1,
                    document_type   => 'passport',
                    status          => 'verified'
                },
                expected => {
                    db_hits       => 1,
                    files         => 0,
                    download_hits => 0,
                },
            },
            {
                query => {
                    issuing_country => 'br',
                    total           => 9,
                    side            => 'front',
                    page_size       => 1,
                    document_type   => 'passport',
                    status          => 'verified'
                },
                expected => {
                    db_hits       => 3,
                    files         => 2,
                    download_hits => 2,
                },
            },
            {
                query => {
                    issuing_country => 'br',
                    total           => 9,
                    page_size       => 1,
                    document_type   => 'passport',
                    status          => 'verified'
                },
                expected => {
                    db_hits       => 3,
                    files         => 2,
                    download_hits => 0,
                },
            },
            {
                query => {
                    issuing_country => 'co',
                    total           => 7,
                    page_size       => 7,
                    document_type   => 'passport',
                    status          => 'rejected'
                },
                expected => {
                    db_hits       => 1,
                    files         => 0,
                    download_hits => 0,
                },
            },
        ];

        my $files_repository = {};

        for my $test ($tests->@*) {
            my ($query, $expected) = @{$test}{qw/query expected/};
            my ($issuing_country, $total, $document_type, $side, $status) = @{$query}{qw/issuing_country total document_type side status/};
            my $str_side         = $side // '(no side)';
            my $curr_total_files = $total_files;

            subtest "querying for $total $status $str_side $document_type" => sub {
                $db_hits       = 0;
                $download_hits = 0;

                $blob = join '|', $status, $document_type, $issuing_country;

                my $real_args = {
                    $args->%*,
                    $query->%*,
                    # optionals must be explicitly provided to avoid pain and anguish
                    side      => $query->{side},
                    page_size => $query->{page_size},
                };

                my $result;

                $exception = exception { $result = BOM::User::Script::PictureCollector->run($real_args)->get(); };

                my $files_counter = 0;

                for my $res_country (keys $result->%*) {
                    for my $res_type (keys $result->{$res_country}->%*) {
                        for my $res_status (keys $result->{$res_country}->{$res_type}->%*) {
                            my $res_files = $result->{$res_country}->{$res_type}->{$res_status};

                            $files_counter = scalar $res_files->@*;

                            for my $res_file ($res_files->@*) {
                                my $file_path = join '/', $folder, $res_country, $res_type, $res_status, $res_file;

                                $files_repository->{$file_path} = 1;

                                open FH, '<', $file_path;

                                while (<FH>) {
                                    is $_, $blob, 'Expected blob';
                                }

                                close(FH);
                            }
                        }
                    }
                }

                ok !$exception, 'No exception observed';
                is $db_hits, $expected->{db_hits},
                    sprintf("Expected DB hits = %d (%d/%d)", $expected->{db_hits}, $real_args->{total}, $real_args->{page_size});
                is $files_counter, $expected->{files},         'Expected number of files in the folder = ' . $expected->{files};
                is $download_hits, $expected->{download_hits}, 'Expected number of files downloaded = ' . $expected->{download_hits};

                $total_files = 0;
                find(\&file_counter, $folder);
                is scalar keys $files_repository->%*, $total_files, sprintf('Bundle has %d files', $total_files);
            };
        }

        $mock->unmock_all;
        rmtree($folder);
    };

    subtest 'download' => sub {
        my $s3_mock = Test::MockModule->new('BOM::Platform::S3Client');
        my $s3_exception;
        my $s3_url;

        $s3_mock->mock(
            'get_s3_url',
            sub {
                die $s3_exception if $s3_exception;

                return $s3_url;
            });

        my $tiny_mock = Test::MockModule->new('HTTP::Tiny');
        my $tiny_exception;
        my $tiny_response;
        my @tiny_params;

        $tiny_mock->mock(
            'get',
            sub {
                @tiny_params = @_;

                die $tiny_exception if $tiny_exception;

                return $tiny_response;
            });

        my $exception;

        subtest 's3 exception' => sub {
            $s3_exception = 'something awful!';
            $exception    = exception {
                ok !BOM::User::Script::PictureCollector->download({
                        file_name => 'test.png',
                    })->get();
            };

            ok $exception =~ qr/$s3_exception/, 'S3 had an exception';
        };

        subtest 'tiny exception' => sub {
            $s3_exception   = undef;
            $tiny_exception = 'thick gloom here!';
            $s3_url         = 'http://127.0.0.1/test.png';

            $exception = exception {
                ok !BOM::User::Script::PictureCollector->download({
                        file_name => 'test.png',
                    })->get();
            };

            is $tiny_params[1], $s3_url, 'Expected get URL';

            ok $exception =~ qr/$tiny_exception/, 'Tiny had an exception';
        };

        subtest 'not 200 status code' => sub {
            $s3_exception   = undef;
            $tiny_exception = undef;
            $s3_url         = 'http://127.0.0.1/test2.png';

            $tiny_response = {
                status   => 403,
                response => 'You are not authorized',
            };

            $exception = exception {
                ok !BOM::User::Script::PictureCollector->download({
                        file_name => 'test2.png',
                    })->get();
            };

            is $tiny_params[1], $s3_url, 'Expected get URL';
            ok !$exception, 'No exception thrown';
        };

        subtest '200 status code' => sub {
            $s3_exception   = undef;
            $tiny_exception = undef;
            $s3_url         = 'http://127.0.0.1/test3.png';

            $tiny_response = {
                status  => 200,
                content => 'here is your blob mate',
            };

            $exception = exception {
                is(
                    BOM::User::Script::PictureCollector->download({
                            file_name => 'test3.png',
                        }
                    )->get(),
                    $tiny_response->{content},
                    'Expected content'
                );
            };

            is $tiny_params[1], $s3_url, 'Expected get URL';
            ok !$exception, 'No exception thrown';
        };

        $s3_mock->unmock_all;
        $tiny_mock->unmock_all;
    };
};

my $c = 0;

sub seed {
    my ($n, $args) = @_;

    my ($side, $type, $country, $status) = @{$args}{qw/side type country status/};

    my $stash = [];

    for my $i (1 .. $n) {
        $c++;

        my $user = BOM::User->create(
            email    => 'someclient' . $c . '@binary.com',
            password => 'Secret0'
        );

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $user->add_client($client);
        $client->binary_user_id($user->id);
        $client->save;

        push $stash->@*,
            upload(
            $client,
            {
                document_type   => $type,
                page_type       => $side // 'front',
                issuing_country => $country,
                document_format => 'PNG',
                checksum        => 'checkthis' . $i,
                document_id     => 'test',
                status          => $status,
            });
    }

    return $stash;
}

sub upload {
    my ($client, $doc) = @_;

    my $file = $client->start_document_upload($doc);

    return $client->finish_document_upload($file->{file_id}, $doc->{status});
}

sub file_counter {
    -f && $total_files++;
}

done_testing();
