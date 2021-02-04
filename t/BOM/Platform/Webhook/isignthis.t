use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Config;
use Mojo::JSON qw(encode_json);
use Digest::SHA qw(hmac_sha256_base64);

my $t                  = Test::Mojo->new('BOM::Platform::Webhook');
my $config             = BOM::Config::third_party();
my $notification_token = $config->{isignthis}->{notification_token} // 'dummy';
my $collector_mock     = Test::MockModule->new('BOM::Platform::Webhook::ISignThis');
my $emit_mock          = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $mock_params;
my $expected_data;
my $signature;

$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->remove('X-ISX-Checksum');
        $tx->req->headers->add('X-ISX-Checksum' => $signature) if defined $signature;
    });

my @metrics;

$collector_mock->mock(
    'stats_inc',
    sub {
        push @metrics, @_;
        return 1;
    });

$emit_mock->mock(
    'emit',
    sub {
        my ($event, $args) = @_;
        is $event, 'dispute_notification', 'Event correctly emitted';
        is $args->{provider}, 'isignthis', 'Provider looks good';
        cmp_deeply $args->{data}, $expected_data, 'Data looks good';
        return 1;
    });

my $hasher = sub {
    my $payload  = shift;
    my $json     = encode_json $payload;
    my $checksum = hmac_sha256_base64($json, $notification_token);
    while (length($checksum) % 4) {
        $checksum .= '=';
    }

    return $checksum;
};

subtest 'Missing checksum header' => sub {
    my $payload = {
        id     => '885e3506-eb13-4d2c-bc24-e336aaf94037',
        secret => '083daa84-77b6-4817-a4f3-5771779c1c82',
        event  => 'dispute_flagged',
    };

    @metrics   = ();
    $signature = undef;
    $t->post_ok('/isignthis', json => $payload)->status_is(401)->json_is(undef);
    is $metrics[0], 'bom_platform.isignthis.webhook.missing_checksum_header', 'Checksum mismatch reported';
};

subtest 'Checksum Mismatch' => sub {
    my $payload = {
        id     => '885e3506-eb13-4d2c-bc24-e336aaf94037',
        secret => '083daa84-77b6-4817-a4f3-5771779c1c82',
        event  => 'dispute_flagged',
    };

    @metrics   = ();
    $signature = 'invalid';
    $t->post_ok('/isignthis', json => $payload)->status_is(401)->json_is(undef);
    is $metrics[0], 'bom_platform.isignthis.webhook.checksum_mismatch', 'Checksum mismatch reported';
};

subtest 'Bogus Payload' => sub {
    my $payload = {
        id     => '885e3506-eb13-4d2c-bc24-e336aaf94037',
        secret => '083daa84-77b6-4817-a4f3-5771779c1c82',
    };

    @metrics   = ();
    $signature = $hasher->($payload);
    $t->post_ok('/isignthis', json => $payload)->status_is(401)->json_is(undef);
    is $metrics[0], 'bom_platform.isignthis.webhook.bogus_payload', 'Bogus payload reported';
};

subtest 'Correct checksum, event dispute_flagged emitted' => sub {
    my $payload = {
        id     => '885e3506-eb13-4d2c-bc24-e336aaf94037',
        secret => '083daa84-77b6-4817-a4f3-5771779c1c82',
        event  => 'dispute_flagged',
    };

    @metrics       = ();
    $signature     = $hasher->($payload);
    $expected_data = $payload;
    $t->post_ok('/isignthis', json => $payload)->status_is(200)->json_is('ok');
    is $metrics[0], 'bom_platform.isignthis.webhook.dispute_flagged', 'Dispute Flagged event reported';
};

subtest 'Correct checksum, event fraud_flagged emitted' => sub {
    my $payload = {
        id     => '885e3506-eb13-4d2c-bc24-e336aaf94037',
        secret => '083daa84-77b6-4817-a4f3-5771779c1c82',
        event  => 'fraud_flagged',
    };

    @metrics       = ();
    $signature     = $hasher->($payload);
    $expected_data = $payload;
    $t->post_ok('/isignthis', json => $payload)->status_is(200)->json_is('ok');
    is $metrics[0], 'bom_platform.isignthis.webhook.fraud_flagged', 'Fraud Flagged event reported';
};

$collector_mock->unmock_all;
$emit_mock->unmock_all;
done_testing();
