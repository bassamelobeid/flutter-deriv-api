use strict;
use warnings;

use Test::Most;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::RPC::v3::Utility;
use YAML::XS qw(LoadFile);
use BOM::Config::RedisReplicated;
use JSON::MaybeXS qw{decode_json};

subtest 'check if test saves ' => sub {

    my $mock_client_residence = 'UK';
    my $mock_client_ip        = '211.24.114.86';
    my $mock_country_code     = 'MY';
    my $mock_client_login_id  = 'MX1234567';
    my $redis_masterkey       = 'IP_COUNTRY_MISMATCH';
    my $check_flag            = 'always';
    my $redis                 = BOM::Config::RedisReplicated::redis_write();

    BOM::RPC::v3::Utility::check_ip_country(
        client_residence => $mock_client_residence,
        client_ip        => $mock_client_ip,
        country_code     => $mock_country_code,
        client_login_id  => $mock_client_login_id,
        check_flag       => $check_flag
    );

    ok(defined $redis->hget($redis_masterkey, $mock_client_login_id), "redis record exists and defined");
    my $data = decode_json $redis->hget($redis_masterkey, $mock_client_login_id);
    ok($data->{ip_country} eq $mock_country_code,           "Correct country_ip");
    ok($data->{ip_address} eq $mock_client_ip,              "Correct ip_address");
    ok($data->{client_residence} eq $mock_client_residence, "Correct client_residence");
    $redis->hdel($redis_masterkey, $mock_client_login_id);
    ok(not(defined $redis->hget($redis_masterkey, $mock_client_login_id)), "redis record deleted");
};

done_testing();
