use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;

use BOM::TradingPlatform::CTrader;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my $user   = BOM::User->create(
    email    => $client->email,
    password => 'test'
);
$user->add_client($client);

subtest 'generate_login_token' => sub {
    my $ctrader = BOM::TradingPlatform::CTrader->new(
        client => $client,
        user   => $user
    );

    like exception { $ctrader->generate_login_token() }, qr/^user_agent is mandatory argument/, 'User agent is validated';
    my $error = exception { $ctrader->generate_login_token('Mozzila 5.0') };
    is $error->{error_code}, 'CTraderAccountNotFound', 'Cannot generate token for user without cTrader account';

    $user->add_loginid('CTR1', 'ctrader', 'real', 'USD', {ctid => 1});
    $ctrader->_add_ctid_userid(1);

    my $token = $ctrader->generate_login_token('Mozzila 5.0');
    ok $token, 'Token is generated';

    my $token1 = $ctrader->generate_login_token('Mozzila 5.0');
    isnt $token, $token1, 'Tokens are uniq';
};

subtest 'decode_login_token' => sub {
    my $ctrader = BOM::TradingPlatform::CTrader->new(
        client => $client,
        user   => $user
    );

    like exception { $ctrader->decode_login_token() },                       qr/^INVALID_TOKEN/, 'Token is validated';
    like exception { $ctrader->decode_login_token('Test_Invalid_Token') },   qr/^INVALID_TOKEN/, 'Token is validated';
    like exception { $ctrader->decode_login_token('token_looks_valid_01') }, qr/^INVALID_TOKEN/, 'Token is validated';

    my $token = $ctrader->generate_login_token('Mozzila 5.0');

    my $param = $ctrader->decode_login_token($token);

    is $param->{ctid},           1,             'Token has valid ctid';
    is $param->{ua_fingerprint}, 'Mozzila 5.0', 'Token has valid User Agent';
    is $param->{user_id},        $user->id,     'Token has valid user id';

    like exception { $ctrader->decode_login_token($token) }, qr/^INVALID_TOKEN/, 'Token is valid only one time ';
};

done_testing();
