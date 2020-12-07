use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Platform::Acquired::Webhook;
use BOM::Config;
use Digest::SHA qw(hmac_sha256_hex);
use Mojo::JSON qw(encode_json);
use Digest::SHA qw(sha256_hex);

my $t                = Test::Mojo->new('BOM::Platform::Acquired::Webhook');
my $config           = BOM::Config::third_party();
my $company_hashcode = $config->{acquired}->{company_hashcode} // 'dummy';
my $collector_mock   = Test::MockModule->new('BOM::Platform::Acquired::Webhook::Collector');
my $emit_mock        = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $mock_params;
my $expected_data;

$collector_mock->mock(
    'stats_inc',
    sub {
        return 1;
    });

$emit_mock->mock(
    'emit',
    sub {
        my ($event, $args) = @_;
        is $event, 'dispute_notification', 'Event correctly emitted';
        is $args->{provider}, 'acquired', 'Provider looks good';
        cmp_deeply $args->{data}, $expected_data, 'Data looks good';
        return 1;
    });

my $hasher = sub {
    my $payload  = shift;
    my $plain    = join '', ($payload->{id}, $payload->{timestamp}, $payload->{company_id}, $payload->{event});
    my $temp     = sha256_hex($plain);
    my $expected = join '', ($temp, $company_hashcode);
    return sha256_hex($expected);
};

subtest 'Hash Mismatch' => sub {
    my $payload = {
        id         => 1,
        timestamp  => 16000000000,
        company_id => 'deriv',
        event      => 'fraud_new',
        hash       => 'invalid'
    };
    my $json = encode_json $payload;
    $t->post_ok('/', json => $payload)->status_is(401)->json_is(undef);
};

subtest 'Correct hash, event fraud_new emitted' => sub {
    # This is a real payload sample from webhook
    my $payload = {
        id         => 'fea514d1-272d-4fed-bad3-0f4e19e88918',
        timestamp  => '15012018182020',
        company_id => '126',
        mid        => '1187',
        event      => 'fraud_new',
        list       => [{
                transaction_id    => '10680696',
                merchant_order_id => '5990700',
                parent_id         => '',
                arn               => '74567618008180083399312',
                rrn               => '720010680696',
                fraud             => {
                    fraud_id    => '',
                    date        => '2018-01-15',
                    amount      => '130.52',
                    currency    => 'USD',
                    auto_refund => false
                },
                history => {
                    retrieval_id => '',
                    fraud_id     => '',
                    dispute_id   => ''
                }}]};

    $payload->{hash} = $hasher->($payload);

    my $json = encode_json $payload;
    $expected_data = $payload;
    $t->post_ok('/', json => $payload)->status_is(200)->json_is('ok');
};

subtest 'Correct hash, event dispute_new emitted' => sub {
    # This is a real payload sample from webhook
    my $payload = {
        id         => 'C9EDECD6-D0B5-AED5-48E6-EF235ECD5A54',
        timestamp  => '20200626110608',
        company_id => '207',
        hash       => '282ae91439a1b214046ee8020a641ec1acb969008b68e77ac6e75478331d80f5',
        event      => 'dispute_new',
        list       => [{
                mid               => '1111',
                transaction_id    => '38311111',
                merchant_order_id => '1234567_001',
                parent_id         => '38311109',
                arn               => '74089120120017577925402',
                rrn               => '012011111111',
                dispute           => {
                    dispute_id  => 'CB_38317766_334344',
                    reason_code => '10.4',
                    description => 'Fraud',
                    date        => '2020-01-01',
                    amount      => '19.95',
                    currency    => 'GBP'
                },
                history => {
                    retrieval_id => '0',
                    fraud_id     => '0',
                    dispute_id   => '0'
                }}]};

    $payload->{hash} = $hasher->($payload);

    my $json = encode_json $payload;
    $expected_data = $payload;
    $t->post_ok('/', json => $payload)->status_is(200)->json_is('ok');
};

$collector_mock->unmock_all;
$emit_mock->unmock_all;
done_testing();
