use strict;
use warnings;

use Test::More;
use Test::MockTime qw( :all );
use Test::MockModule;
use Test::Deep;
use BOM::Event::Script::OnfidoSuspendedRetry;
use BOM::Config::Redis;
use BOM::User::Onfido;
use Future;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Script::OnfidoMock;
use BOM::Config::Runtime;
use BOM::Event::Services;
use IO::Async::Loop;

my $script   = BOM::Event::Script::OnfidoSuspendedRetry->new;
my $loop     = IO::Async::Loop->new;
my $services = BOM::Event::Services->new;
$loop->add($services);
my $onfido = $services->onfido();

subtest 'Onfido is still suspended' => sub {
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @doggy_bag;

    $dog_mock->mock(
        'stats_inc',
        sub {
            push @doggy_bag, @_;
        });

    @doggy_bag = ();
    BOM::Config::Runtime->instance->app_config->system->suspend->onfido(1);

    $script->run(5)->get;

    cmp_deeply [@doggy_bag], ['onfido.suspended.true'], 'Onfido is still suspended';

    @doggy_bag = ();
    BOM::Config::Runtime->instance->app_config->system->suspend->onfido(0);

    $script->run(5)->get;

    cmp_deeply [@doggy_bag], ['onfido.suspended.false'], 'Onfido is back';
};

subtest 'ZSET pagination' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->onfido(0);
    my $mock  = Test::MockModule->new('BOM::Event::Script::OnfidoSuspendedRetry');
    my $redis = BOM::Config::Redis::redis_events();
    my @process_stack;

    $mock->mock(
        'process',
        sub {
            shift;
            push @process_stack, shift;

            return Future->done();
        });

    my $loop_mock = Test::MockModule->new('IO::Async::Loop');
    my $delays;
    $loop_mock->mock(
        'delay_future',
        sub {
            $delays++;

            return Future->done;
        });

    my $limit = 23;
    my $time  = time;

    for (1 .. $limit) {
        $redis->zadd(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, $time + $_, $_);
    }

    $delays = 0;
    $script->run(5)->get;
    is $delays, 5, 'expected delays';

    my $zset = $redis->zrangebyscore(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, '-Inf', '+Inf', 'WITHSCORES');

    cmp_deeply $zset, [map { ($_, $time + $_) } (6 .. $limit)], 'expected zset remaining';

    cmp_deeply [@process_stack], [1 .. 5], 'expected users processed';

    @process_stack = ();

    $delays = 0;
    $script->run(5)->get;
    is $delays, 5, 'expected delays';

    $zset = $redis->zrangebyscore(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, '-Inf', '+Inf', 'WITHSCORES');

    cmp_deeply $zset, [map { ($_, $time + $_) } (11 .. $limit)], 'expected zset remaining';

    cmp_deeply [@process_stack], [6 .. 10], 'expected users processed';

    @process_stack = ();

    $delays = 0;
    $script->run(5)->get;
    is $delays, 5, 'expected delays';

    $zset = $redis->zrangebyscore(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, '-Inf', '+Inf', 'WITHSCORES');

    cmp_deeply $zset, [map { ($_, $time + $_) } (16 .. $limit)], 'expected zset remaining';

    cmp_deeply [@process_stack], [11 .. 15], 'expected users processed';

    @process_stack = ();

    $delays = 0;
    $script->run(5)->get;
    is $delays, 5, 'expected delays';

    $zset = $redis->zrangebyscore(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, '-Inf', '+Inf', 'WITHSCORES');

    cmp_deeply $zset, [map { ($_, $time + $_) } (21 .. $limit)], 'expected zset remaining';

    @process_stack = ();

    $delays = 0;
    $script->run(5)->get;
    is $delays, 3, 'expected delays';

    $zset = $redis->zrangebyscore(+BOM::User::Onfido::ONFIDO_SUSPENDED_UPLOADS, '-Inf', '+Inf', 'WITHSCORES');

    cmp_deeply $zset, [], 'expected zset remaining';

    cmp_deeply [@process_stack], [21 .. 23], 'expected users processed';

    $mock->unmock_all;
};

subtest 'Onfido retriggering' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->onfido(0);
    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @doggy_bag;

    $dog_mock->mock(
        'stats_inc',
        sub {
            push @doggy_bag, @_;
        });

    subtest 'invalid binary user id' => sub {
        @doggy_bag = ();
        $script->process(-1)->get;

        cmp_deeply [@doggy_bag],
            ['onfido.suspended.retry', {tags => ['binary_user_id:-1']}, 'onfido.suspended.failure', {tags => ['binary_user_id:-1']}],
            'expected doggy bag when invalid user';
    };

    my $documents_mock = Test::MockModule->new('BOM::User::Onfido');
    my $stash          = [];
    my $documents;

    $documents_mock->mock(
        'candidate_documents',
        sub {
            return $documents;
        });

    subtest 'no documents' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            email          => 'no+documents+retry@bin.com',
            residence      => 'co',
            place_of_birth => 'co',
            citizen        => 'co',
        });

        my $user = BOM::User->create(
            email          => $client->email,
            password       => "hello",
            email_verified => 1,
        );

        $user->add_client($client);
        $client->binary_user_id($user->id);
        $client->save;

        @doggy_bag = ();
        $documents = undef;
        $script->process($user->id)->get;

        cmp_deeply [@doggy_bag],
            [
            'onfido.suspended.retry',        {tags => ['binary_user_id:' . $user->id]},
            'onfido.suspended.no_documents', {tags => ['binary_user_id:' . $user->id]},
            ],
            'expected doggy bag when no documents';
    };

    subtest 'applicant' => sub {
        my $script_mock = Test::MockModule->new(ref($script));
        my $onfido_s3_acrobatics;
        $script_mock->mock(
            's3_onfido_acrobatics',
            sub {
                $onfido_s3_acrobatics = 1;
                return Future->done;
            });

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            email          => 'applicant+suspended@test.com',
            residence      => 'co',
            place_of_birth => 'co',
            citizen        => 'co',
        });

        my $user = BOM::User->create(
            email          => $client->email,
            password       => "hello",
            email_verified => 1,
        );

        $user->add_client($client);
        $client->binary_user_id($user->id);
        $client->save;

        @doggy_bag = ();
        $documents = {
            selfie => build_document({
                    document_type   => 'selfie_with_id',
                    issuing_country => 'br',
                    file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                    id              => 1,
                }
            ),
            documents => [
                build_document({
                        document_type   => 'passport',
                        issuing_country => 'br',
                        file_name       => 'CR1.passport.2_front.jpg',
                        id              => 1,
                    })
            ],
        };

        # weird case: no applicant

        my $onfido_mock = Test::MockModule->new('WebService::Async::Onfido');
        $onfido_mock->mock(
            'applicant_create',
            sub {
                return Future->done(bless {}, 'WebService::Async::Onfido::Applicant');
            });
        $onfido_s3_acrobatics = undef;
        $script->process($user->id)->get;
        is $onfido_s3_acrobatics, undef, 'No acrobatics made';
        cmp_deeply [@doggy_bag],
            [
            'onfido.suspended.retry',        {tags => ['binary_user_id:' . $user->id]},
            'onfido.suspended.no_applicant', {tags => ['binary_user_id:' . $user->id]},
            ],
            'expected doggy bag (no applicant)';
        $onfido_mock->unmock_all;

        # create that applicant
        @doggy_bag            = ();
        $onfido_s3_acrobatics = undef;
        $script->process($user->id)->get;
        is $onfido_s3_acrobatics, 1, 'Acrobatics made';

        my $applicant_data = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);
        my $applicant_id   = $applicant_data->{id};

        cmp_deeply [@doggy_bag],
            [
            'onfido.suspended.retry', {tags => ['binary_user_id:' . $user->id]},
            'onfido.api.hit', 'onfido.suspended.processed',
            {tags => ['binary_user_id:' . $user->id, 'applicant:' . $applicant_id]},
            ],
            'expected doggy bag (applicant created)';

        # make sure the applicant does not get recreated
        @doggy_bag            = ();
        $onfido_s3_acrobatics = undef;
        $script->process($user->id)->get;
        is $onfido_s3_acrobatics, 1, 'Acrobatics made';

        cmp_deeply [@doggy_bag],
            [
            'onfido.suspended.retry',     {tags => ['binary_user_id:' . $user->id]},
            'onfido.suspended.processed', {tags => ['binary_user_id:' . $user->id, 'applicant:' . $applicant_id]},
            ],
            'expected doggy bag (existing applicant)';

        $script_mock->unmock_all;
    };

    subtest 'acrobatics among s3 and Onfido' => sub {
        my $emit_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
        my @emissions;
        $emit_mock->mock(
            'emit',
            sub {
                push @emissions, +{@_};
            });
        my $s3_mock = Test::MockModule->new('BOM::Platform::S3Client');
        $s3_mock->mock(
            'download',
            sub {
                my (undef, $file_name) = @_;

                return Future->done('RAW:' . $file_name);
            });

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            email          => 'accrobatics+retry+suspended@test.com',
            residence      => 'co',
            place_of_birth => 'co',
            citizen        => 'co',
        });

        my $user = BOM::User->create(
            email          => $client->email,
            password       => "hello",
            email_verified => 1,
        );

        $user->add_client($client);
        $client->binary_user_id($user->id);
        $client->save;

        @doggy_bag = ();
        $documents = {
            selfie => build_document({
                    document_type   => 'selfie_with_id',
                    issuing_country => 'br',
                    file_name       => 'CR1.selfie_with_id.1_photo.jpg',
                    id              => 1,
                }
            ),
            documents => [
                build_document({
                        document_type   => 'driving_licence',
                        issuing_country => 'br',
                        file_name       => 'CR1.driving_licence.2_front.jpg',
                        id              => 2,
                    }
                ),
                build_document({
                        document_type   => 'driving_licence',
                        issuing_country => 'br',
                        file_name       => 'CR1.driving_licence.3_back.jpg',
                        id              => 3,
                    })
            ],
        };

        @emissions = ();
        @doggy_bag = ();
        $script->process($user->id)->get;

        my $applicant_data = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);
        my $applicant_id   = $applicant_data->{id};

        cmp_deeply [@doggy_bag],
            [
            'onfido.suspended.retry', {tags => ['binary_user_id:' . $user->id]},
            'onfido.api.hit', 'onfido.api.hit', 'onfido.api.hit', 'onfido.api.hit',
            'onfido.suspended.processed', {tags => ['binary_user_id:' . $user->id, 'applicant:' . $applicant_id]},
            ],
            'expected doggy bag for a well done acrobacy';

        my ($onfido_selfie_db) = values BOM::User::Onfido::get_onfido_live_photo($user->id, $applicant_id)->%*;

        is $onfido_selfie_db->{file_name}, 'CR1.selfie_with_id.1_photo.jpg',             'expected selfie file name';
        is $onfido_selfie_db->{file_size}, 4 + length('CR1.selfie_with_id.1_photo.jpg'), 'expected file size';

        # to stabilize this test, ensure the ordering by extracting the id from the file name
        my ($onfido_document_1, $onfido_document_2) = sort { $b->{file_id} <=> $a->{file_id} } map {
            my ($id) = $_->{file_name} =~ /\.(\d+)_/;
            $_->{file_id} = $id;
            $_;
        } values BOM::User::Onfido::get_onfido_document($user->id, $applicant_id)->%*;
        is $onfido_document_1->{file_name}, 'CR1.driving_licence.3_back.jpg',              'expected document file name';
        is $onfido_document_1->{file_size}, 4 + length('CR1.driving_licence.3_back.jpg'),  'expected file size';
        is $onfido_document_2->{file_name}, 'CR1.driving_licence.2_front.jpg',             'expected document file name';
        is $onfido_document_2->{file_size}, 4 + length('CR1.driving_licence.2_front.jpg'), 'expected file size';
        $s3_mock->unmock_all;

        # now let's check those photos
        my ($blob1, $blob2, $blob3) = Future->needs_all(
            $onfido->download_document(
                applicant_id => $applicant_id,
                document_id  => $onfido_document_1->{id},
            ),
            $onfido->download_document(
                applicant_id => $applicant_id,
                document_id  => $onfido_document_2->{id},
            ),
            $onfido->download_photo(
                applicant_id  => $applicant_id,
                live_photo_id => $onfido_selfie_db->{id},
            ))->get;

        cmp_deeply [$blob1, $blob2, $blob3],
            ['RAW:' . $onfido_document_1->{file_name}, 'RAW:' . $onfido_document_2->{file_name}, 'RAW:' . $onfido_selfie_db->{file_name},],
            'Expected picture contents';

        # check the emission
        cmp_deeply [@emissions],
            [{
                ready_for_authentication => {
                    loginid      => $client->loginid,
                    applicant_id => $applicant_id,
                    documents    => [$onfido_document_2->{id}, $onfido_document_1->{id}, $onfido_selfie_db->{id}]}}
            ],
            'Expected emissions';

        $emit_mock->unmock_all;
        $s3_mock->unmock_all;
    };
};

sub build_document {
    my $args = shift;

    return (bless $args, 'BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument');
}

done_testing();
