use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Config;
use JSON;
use MIME::Base64;

my $t              = Test::Mojo->new('BOM::Platform::Webhook');
my $config         = BOM::Config::third_party();
my $collector_mock = Test::MockModule->new('BOM::Platform::Webhook::IDV');
my $emit_mock      = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $mock_params;
my $expected_data;
my $headers;
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
        is $event, 'idv_webhook', 'Event correctly emitted';
        cmp_deeply $args->{body}->{json}, $expected_data,                                   'JSON data looks good';
        cmp_deeply $args->{body}->{raw},  encode_base64(JSON::encode_json($expected_data)), 'Base64 data looks good';
        cmp_deeply $args->{headers},      $headers,                                         'Headers ok';
        return 1;
    });

subtest 'ok test' => sub {
    my $payload = '885e3506-eb13-4d2c-bc24-e336aaf94037';
    $headers = {
        'Content-Type'    => 'application/json',
        'Host'            => re('.*'),
        'User-Agent'      => 'Mojolicious (Perl)',
        'Content-Length'  => '38',
        'Accept-Encoding' => 'gzip'
    };

    @metrics       = ();
    $signature     = undef;
    $expected_data = $payload;
    $t->post_ok(
        '/idv',
        json    => $payload,
        headers => $headers
    )->status_is(200)->json_is('ok');
    is $metrics[0], 'bom_platform.webhook.idv_webhook_received', 'IDV Webhook Received Reported';
};

subtest 'not ok test' => sub {
    my $payload = {json => '885e3506-eb13-4d2c-bc24-e336aaf94037'};

    @metrics       = ();
    $signature     = undef;
    $expected_data = $payload;

    $t->post_ok('/idv', form => $payload)->status_is(400)->json_is(undef);
    is $metrics[0], 'bom_platform.idv.webhook.bogus_payload', 'Bad Request Reported';
};

$collector_mock->unmock_all;
$emit_mock->unmock_all;
done_testing();
