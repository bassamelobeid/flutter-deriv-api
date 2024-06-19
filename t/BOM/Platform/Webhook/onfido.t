use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Config;
use Mojo::JSON qw(encode_json);
use Digest::HMAC;
use Digest::SHA1;
use Digest::SHA qw(hmac_sha256_hex);
use Log::Any::Test;
use Log::Any qw($log);

my $t          = Test::Mojo->new('BOM::Platform::Onfido::Webhook');
my $config     = BOM::Config::third_party();
my $token      = $config->{onfido}->{webhook_token} // 'dummy';
my $check_mock = Test::MockModule->new('BOM::Platform::Onfido::Webhook::Check');
my $emit_mock  = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $mock_params;
my $expected_data;
my @metrics;
my $sig;
my $sig256;
my $emissions;

my $old_challenge = sub {
    my $digest = Digest::HMAC->new($token, 'Digest::SHA1');
    $digest->add(encode_json shift);
    $sig256 = undef;
    $sig    = $digest->hexdigest;
    return $sig;
};

my $new_challenge = sub {
    $sig    = undef;
    $sig256 = hmac_sha256_hex(encode_json(shift), $token);
    return $sig256;
};

$t->ua->on(
    start => sub {
        my ($ua, $tx) = @_;
        $tx->req->headers->remove('X-Signature');
        $tx->req->headers->remove('X-SHA2-Signature');
        $tx->req->headers->add('X-Signature'      => $sig)    if defined $sig;
        $tx->req->headers->add('X-SHA2-Signature' => $sig256) if defined $sig256;
    });

$check_mock->mock(
    'stats_inc',
    sub {
        push @metrics, @_ if scalar @_ == 2;
        push @metrics, @_, undef if scalar @_ == 1;
        return 1;
    });

$emit_mock->mock(
    'emit',
    sub {
        my ($event, $args) = @_;
        $emissions->{$event} = $args;
        return 1;
    });

subtest 'No signature request' => sub {
    my $payload = {

    };

    my $json = encode_json $payload;
    @metrics = ();
    $log->clear();
    $t->post_ok('/', json => $payload)->status_is(200)->content_is('failed');

    cmp_deeply + {@metrics},
        +{
        'webhook.onfido.dispatch'          => undef,
        'webhook.onfido.invalid_signature' => undef,
        'bom.platform'                     => {tags => ['onfido.signature.header.notfound']}
        },
        'Expected dd metrics';

    cmp_bag $log->msgs,
        [{
            level    => 'debug',
            message  => 'no signature header found',
            category => 'BOM::Platform::Onfido::Webhook::Check'
        }
        ],
        'Expected log messages';
};

subtest 'Old challenge failure' => sub {
    my $payload = {
        test => 1,
    };

    $old_challenge->($payload);
    $sig .= 'makemefail';

    my $json = encode_json $payload;
    @metrics = ();
    $log->clear();
    $t->post_ok('/', json => $payload)->status_is(200)->content_is('failed');

    cmp_deeply + {@metrics},
        +{
        'webhook.onfido.dispatch' => undef,
        'webhook.onfido.failure'  => undef,
        },
        'Expected dd metrics';

    cmp_bag $log->msgs,
        [{
            category => 'BOM::Platform::Onfido::Webhook::Check',
            message  => "Signature is $sig",
            level    => 'debug'
        },
        {
            level    => 'error',
            message  => re('Failed - Signature mismatch'),
            category => 'BOM::Platform::Onfido::Webhook::Check'
        }
        ],
        'Expected log messages';
};

subtest 'Old challenge success' => sub {
    my $payload = {
        test => 1,
    };

    $old_challenge->($payload);

    my $json = encode_json $payload;
    @metrics = ();
    $log->clear();
    $emissions = {};
    $t->post_ok('/', json => $payload)->status_is(200)->content_is('ok');

    cmp_deeply + {@metrics},
        +{
        'webhook.onfido.dispatch'          => undef,
        'webhook.onfido.unexpected_action' => undef,
        },
        'Expected dd metrics';
    cmp_deeply $emissions, +{}, 'Expected emissions';

    cmp_bag $log->msgs,
        [{
            message  => "Signature is $sig",
            category => 'BOM::Platform::Onfido::Webhook::Check',
            level    => 'debug'
        },
        {
            level    => 'debug',
            category => 'BOM::Platform::Onfido::Webhook::Check',
            message  => 'Received check {test => 1} from Onfido'
        },
        {
            level    => 'warning',
            category => 'BOM::Platform::Onfido::Webhook::Check',
            message  => 'Unexpected check action, ignoring: <undef>'
        }
        ],
        'Expected log messages';
};

subtest 'New challenge failure' => sub {
    my $payload = {
        payload => {
            action => 'check.completed',
        }};

    $new_challenge->($payload);
    $sig256 .= 'failme';

    my $json = encode_json $payload;
    @metrics = ();
    $log->clear();
    $emissions = {};
    $t->post_ok('/', json => $payload)->status_is(200)->content_is('failed');

    cmp_deeply + {@metrics},
        +{
        'webhook.onfido.dispatch' => undef,
        'webhook.onfido.failure'  => undef,
        },
        'Expected dd metrics';
    cmp_deeply $emissions, +{}, 'Expected emissions';

    cmp_bag $log->msgs,
        [{
            category => 'BOM::Platform::Onfido::Webhook::Check',
            level    => 'debug',
            message  => "Signature is $sig256"
        },
        {
            category => 'BOM::Platform::Onfido::Webhook::Check',
            level    => 'error',
            message  => re('Failed - Signature mismatch')}
        ],
        'Expected log messages';
};

subtest 'New challenge success' => sub {
    my $payload = {
        payload => {
            action => 'check.completed',
            object => {
                href   => 'test',
                status => 'asdf',
            }}};

    $new_challenge->($payload);

    my $json = encode_json $payload;
    @metrics   = ();
    $emissions = {};
    $log->clear();
    $t->post_ok('/', json => $payload)->status_is(200)->content_is('ok');

    cmp_deeply + {@metrics},
        +{
        'webhook.onfido.dispatch' => undef,
        'webhook.onfido.success'  => undef,
        },
        'Expected dd metrics';
    cmp_deeply $emissions,
        +{
        client_verification => {
            check_url => 'test',
            status    => 'asdf',
        }
        },
        'Expected emissions';

    cmp_bag $log->msgs,
        [{
            level    => 'debug',
            category => 'BOM::Platform::Onfido::Webhook::Check',
            message  => "Signature is $sig256"
        },
        {
            category => 'BOM::Platform::Onfido::Webhook::Check',
            message  => 'Received check {payload => {action => "check.completed",object => {href => "test",status => "asdf"}}} from Onfido',
            level    => 'debug'
        },
        {
            level    => 'debug',
            category => 'BOM::Platform::Onfido::Webhook::Check',
            message  => 'Emitting client_verification event for test (status asdf)'
        }
        ],
        'Expected log messages';
};

$check_mock->unmock_all;
$emit_mock->unmock_all;
done_testing();
