use Test::More;
use Test::Mojo;
use Test::MockModule;
use BOM::Platform::Sendbird::Webhook;
use BOM::Config;
use Digest::SHA qw(hmac_sha256_hex);
use Mojo::JSON qw(encode_json);
use BOM::Database::ClientDB;

my $t              = Test::Mojo->new('BOM::Platform::Sendbird::Webhook');
my $config         = BOM::Config::third_party();
my $token          = $config->{sendbird}->{api_token};
my $collector_mock = Test::MockModule->new('BOM::Platform::Sendbird::Webhook::Collector');

$collector_mock->mock(
    'p2p_chat_message_add',
    sub {
        return 1;
    });

$collector_mock->mock(
    'stats_inc',
    sub {
        return 1;
    });

subtest 'Signature Mismatch' => sub {
    my $payload   = {test => 123};
    my $json      = encode_json $payload;
    my $signature = hmac_sha256_hex($json, $token) + '_badSignature';

    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->remove('X-Sendbird-Signature');
            $tx->req->headers->add('X-Sendbird-Signature' => $signature);
        });

    $t->post_ok('/', json => $payload)->status_is(401)->json_is(undef);
};

subtest 'Correct signature, not valid payload' => sub {
    my $payload   = {test => 123};
    my $json      = encode_json $payload;
    my $signature = hmac_sha256_hex($json, $token);

    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->remove('X-Sendbird-Signature');
            $tx->req->headers->add('X-Sendbird-Signature' => $signature);
        });

    $t->post_ok('/', json => {test => 123})->status_is(200)->json_is(undef);
};

subtest 'Correct signature, message saved' => sub {
    # This is a real payload sample from webhook
    my $payload = {
        category => 'open_channel:message_send',
        sender   => {
            nickname    => 'test',
            user_id     => 'test user ID',
            profile_url => '',
            metadata    => {}
        },
        custom_type     => '',
        mention_type    => 'users',
        mentioned_users => [],
        app_id          => '3C6B5C02-BEB1-4092-BCCB-02EDDC0A0AE1',
        type            => 'MESG',
        payload         => {
            custom_type  => '',
            created_at   => 1593547606693,
            translations => {},
            message      => 'This is a test msg',
            data         => '',
            message_id   => 911845165
        },
        channel => {
            data        => 'Hola mundo',
            channel_url => 'sendbird_open_channel_1962_9441ed29ee28b543cb9971afc22587b8f662e944',
            name        => 'my first channel',
            custom_type => 'test'
        },
        sdk => 'JavaScript'
    };

    my $json = encode_json $payload;
    my $signature = hmac_sha256_hex($json, $token);

    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->remove('X-Sendbird-Signature');
            $tx->req->headers->add('X-Sendbird-Signature' => $signature);
        });

    $t->post_ok('/', json => $payload)->status_is(200)->json_is('ok');
};

subtest 'Correct signature, file type message saved' => sub {
    # This is a real payload sample from webhook
    my $payload = {
        category => 'open_channel:message_send',
        sender   => {
            nickname    => 'test',
            user_id     => 'test user ID',
            profile_url => '',
            metadata    => {}
        },
        custom_type     => '',
        mention_type    => 'users',
        mentioned_users => [],
        app_id          => '3C6B5C02-BEB1-4092-BCCB-02EDDC0A0AE1',
        type            => 'FILE',
        payload         => {
            custom_type  => '',
            url          => 'https://file-us-1.sendbird.com/bee16c535ce043a4be61dd34d087372a.png',
            content_size => 18385,
            created_at   => 1593548441551,
            filename     => 'deriv-zoom-dark.png',
            content_type => 'image/png',
            data         => '',
            message_id   => 911866631
        },
        channel => {
            data        => 'Hola mundo',
            channel_url => 'sendbird_open_channel_1962_9441ed29ee28b543cb9971afc22587b8f662e944',
            name        => 'my first channel',
            custom_type => 'test'
        },
        sdk => 'JavaScript'
    };

    my $json = encode_json $payload;
    my $signature = hmac_sha256_hex($json, $token);

    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->remove('X-Sendbird-Signature');
            $tx->req->headers->add('X-Sendbird-Signature' => $signature);
        });

    $t->post_ok('/', json => $payload)->status_is(200)->json_is('ok');
};

$collector_mock->unmock_all;
done_testing();
