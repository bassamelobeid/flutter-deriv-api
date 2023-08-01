use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;

use BOM::TradingPlatform::CTrader;

# Preparing data and mocks
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

my @mocked_ctrader_logins = ();
my $user_mock             = Test::MockModule->new('BOM::User');
$user_mock->mock(
    ctrade_loginids => sub { return @mocked_ctrader_logins },
    loginid_details => {CTR1 => {attributes => {ctid => 1}}},
);
my $mocked_ctrader = Test::MockModule->new('BOM::TradingPlatform::CTrader');
$mocked_ctrader->mock(
    get_ctid_userid => 1,
);

subtest 'generate_login_token' => sub {
    my $ctrader = BOM::TradingPlatform::CTrader->new(client => $client);

    @mocked_ctrader_logins = ();

    like exception { $ctrader->generate_login_token() }, qr/^user_agent is mandatory argument/, 'User agent is validated';
    like exception { $ctrader->generate_login_token('Mozzila 5.0') }, qr/^No cTrader accounts found for/,
        'Cannot generate token for user without ctrader accoutns';

    @mocked_ctrader_logins = qw(CTR1);
    my $token = $ctrader->generate_login_token('Mozzila 5.0');
    ok $token, 'Token is generated';

    my $token1 = $ctrader->generate_login_token('Mozzila 5.0');
    isnt $token, $token1, 'Tokens are uniq';
};

subtest 'decode_login_token' => sub {
    my $ctrader = BOM::TradingPlatform::CTrader->new(client => $client);

    like exception { $ctrader->decode_login_token() },                       qr/^INVALID_TOKEN/, 'Token is validated';
    like exception { $ctrader->decode_login_token('Test_Invalid_Token') },   qr/^INVALID_TOKEN/, 'Token is validated';
    like exception { $ctrader->decode_login_token('token_looks_valid_01') }, qr/^INVALID_TOKEN/, 'Token is validated';

    @mocked_ctrader_logins = qw(CTR1);
    my $token = $ctrader->generate_login_token('Mozzila 5.0');

    my $param = $ctrader->decode_login_token($token);

    is $param->{ctid},           1,                 'Token has valid ctid';
    is $param->{ua_fingerprint}, 'Mozzila 5.0',     'Token has valid User Agent';
    is $param->{user_id},        $client->user->id, 'Token has valid user id';

    like exception { $ctrader->decode_login_token($token) }, qr/^INVALID_TOKEN/, 'Token is valid only one time ';
};

done_testing();
