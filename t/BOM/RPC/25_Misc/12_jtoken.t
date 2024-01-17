use strict;
use warnings;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client);
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use utf8;
use LandingCompany::Registry;
use BOM::Config::Runtime;
use JSON::WebToken qw(decode_jwt);
use YAML::XS       qw(LoadFile);

my $client = create_client(
    'CR', undef,
    {
        email       => 'dummy@binary.com',
        date_joined => '2021-06-06 23:59:59'
    });

my $res = BOM::RPC::v3::Authorize::jtoken_create({
    client => $client,
});

my $secret = BOM::Config::aes_keys()->{jtoken_secret}{1};

subtest "Check JToken claims" => sub {
    my $claims = decode_jwt $res, $secret, 1, ['HS256'];
    ok $claims->{email} eq $client->{email},                   'email belongs to user';
    ok $claims->{binary_user_id} eq $client->{binary_user_id}, 'date_joined is correct';
    ok $claims->{country} eq $client->{residence},             'country is correct';
    ok $claims->{is_virtual} eq 0,                             'is_virtual is correct';
    ok $claims->{loginid} eq $client->{loginid},               'loginid is correct';
    ok $claims->{sub} eq $client->{binary_user_id},            'sub is correct';
    ok $claims->{broker} eq 'CR',                              'broker is correct';

    my $exp       = $claims->{exp};
    my $expected  = time + 600;
    my $exp_is_ok = $exp >= $expected - 1 || $exp <= $expected;
    ok $exp_is_ok, 'Expire time is correct';
};

done_testing();
