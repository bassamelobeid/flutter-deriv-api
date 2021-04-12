use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::CryptoTestDatabase qw(:init);
use BOM::RPC::v3::Services::Onramp;
use BOM::Config;
use Digest::SHA qw(hmac_sha256_hex);
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

my $email = 'onramp@deriv.com';

my $client_fiat = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
});

my $client_crypto = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
});
$client_crypto->account('BTC');

my $user = BOM::User->create(
    email    => $email,
    password => 'test'
);
$user->add_client($client_fiat);
$user->add_client($client_crypto);

my $mock_config   = Test::MockModule->new('BOM::Config');
my $mock_http     = Test::MockModule->new('Net::Async::HTTP');
my $fake_response = Test::MockObject->new();

subtest general => sub {
    dies_ok { BOM::RPC::v3::Services::Onramp->new(service => 'bong') } 'invalid service name';

    my $o;
    lives_ok { $o = BOM::RPC::v3::Services::Onramp->new(service => 'banxa') } 'create instance';

    my $res = $o->create_order({
            client      => $client_fiat,
            source_type => 'official'
        })->get();
    cmp_deeply(
        $res->{error}{error},
        {
            code              => 'OrderCreationError',
            message_to_client => 'This feature is only available for accounts with crypto as currency.',
        },
        'no currency set'
    );

    $client_fiat->account('USD');

    $res = $o->create_order({
            client      => $client_fiat,
            source_type => 'official'
        })->get();
    cmp_deeply(
        $res->{error}{error},
        {
            code              => 'OrderCreationError',
            message_to_client => 'This feature is only available for accounts with crypto as currency.',
        },
        'USD currency not allowed'
    );
};

subtest banxa => sub {

    my $config = {
        api_url    => 'dummy',
        api_key    => '12345',
        api_secret => 'topsecret'
    };

    $mock_config->mock('third_party' => sub { return {banxa => $config} });

    my $o = BOM::RPC::v3::Services::Onramp->new(service => 'banxa');

    my $res = $o->create_order({client => $client_fiat})->get();
    is($res->{error}{error}{code}, 'PermissionDenied', 'no source_type');

    $res = $o->create_order({
            client      => $client_fiat,
            source_type => 'unofficial'
        })->get();
    is($res->{error}{error}{code}, 'PermissionDenied', 'unofficial source_type');

    my $referrer = 'https://www.deriv.com';
    $fake_response->mock(content => sub { 'hello' });

    $mock_http->mock(
        POST => sub {
            my $payload = decode_json_utf8($_[2]);
            is($payload->{return_url_on_success}, $referrer, 'correct referrer sent');
            return Future->done($fake_response);
        });

    $res = $o->create_order({
            client      => $client_crypto,
            source_type => 'official',
            referrer    => $referrer
        })->get;

    cmp_deeply(
        $res->{error}{error},
        {
            code              => 'ConnectionError',
            message_to_client => re('^malformed JSON string'),
        },
        'API returns invalid json',
    );

    $fake_response->mock(content => sub { '{"errors": "something wrong"}' });
    $res = $o->create_order({
            client      => $client_crypto,
            source_type => 'official',
            args        => {referrer => $referrer}})->get();

    cmp_deeply(
        $res->{error}{error},
        {
            code              => 'OrderCreationError',
            message_to_client => 'Cannot create a Banxa order for ' . $client_crypto->loginid,
        },
        'API returns error',
    );

    my $order_id  = 's4df0ldYfldqj';
    my $order_url = 'www.banxa.com/checkout';

    $fake_response->mock(content => sub { encode_json_utf8({data => {order => {id => $order_id, checkout_url => $order_url}}}) });
    $res = $o->create_order({
            client      => $client_crypto,
            source_type => 'official',
            args        => {referrer => $referrer}})->get();

    cmp_deeply(
        $res,
        {
            token => $order_id,
            url   => $order_url,
        },
        'Valid API response'
    );
};

subtest wyre => sub {

    my $config = {
        api_url        => 'dummy',
        api_account_id => '12345',
        api_secret     => 'topsecret'
    };

    $mock_config->mock('third_party' => sub { return {wyre => $config} });

    my $o = BOM::RPC::v3::Services::Onramp->new(service => 'wyre');

    $fake_response->mock(content => sub { 'hello' });

    $mock_http->mock(
        POST => sub {
            my $payload = decode_json_utf8($_[2]);
            is($payload->{referrerAccountId}, $config->{api_account_id}, 'correct account id sent');
            return Future->done($fake_response);
        });

    my $res = $o->create_order({
            client      => $client_crypto,
            source_type => 'official'
        })->get();
    cmp_deeply(
        $res->{error}{error},
        {
            code              => 'ConnectionError',
            message_to_client => re('^malformed JSON string'),
        },
        'API returns invalid json',
    );

    $fake_response->mock(content => sub { '{"errorCode": "something wrong"}' });
    $res = $o->create_order({
            client      => $client_crypto,
            source_type => 'official'
        })->get();
    cmp_deeply(
        $res->{error}{error},
        {
            code              => 'OrderCreationError',
            message_to_client => 'Cannot create a Wyre reservation for ' . $client_crypto->loginid,
        },
        'API returns error',
    );

    my $wyre_resp = {
        reservation => '8dj3mikv9uG',
        url         => 'www.wyre.com/checkout'
    };
    $fake_response->mock(content => sub { encode_json_utf8($wyre_resp) });
    $res = $o->create_order({
            client      => $client_crypto,
            source_type => 'official'
        })->get();
    cmp_deeply(
        $res,
        {
            token => $wyre_resp->{reservation},
            url   => $wyre_resp->{url},
        },
        'Valid API response'
    );

};

done_testing();
