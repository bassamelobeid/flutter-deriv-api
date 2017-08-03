use strict;
use warnings;

use Test::Most;
use BOM::RPC::v3::Utility;

subtest 'URI scheme should be valid' => sub {
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http:://localhost.com') } 'Bad URL ::';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http:///localhost.com') } 'Bad URL //';
    # dies_ok {BOM::RPC::v3::Utility::validate_uri('http://bla∂.com')} 'Bad URL';
};

subtest 'URI scheme should be http(s)' => sub {
    dies_ok { BOM::RPC::v3::Utility::validate_uri('//localhost.com') } 'URL without scheme';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('localhost.com') } 'URL without slash';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('ftp://localhost.com') } 'URL with ftp scheme';
};

subtest 'URI should not have port' => sub {
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com:8080') } 'URL with port';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com:8080/example') } 'URL with port and sub dir';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com:') } 'URL with missing port';
};

subtest 'URI should not have query' => sub {
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com?') } 'URL with missing query';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com?test=') } 'URL with empty query';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com?test=val1&test2=val2') } 'URL with query';
};

subtest 'URI should not have user info' => sub {
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://@localhost.com') } 'URL with missing userinfo';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://username@localhost.com') } 'URL with username';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://username:password@localhost.com') } 'URL with password';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://username:passwordlocalhost.com') } 'URL with password without @';
};

subtest 'URI should not have fragments' => sub {
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com#') } 'URL with missing fragment without slash';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com/#') } 'URL with missing fragment';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com/#hello') } 'URL with fragment';
};

subtest 'URI should not have IP' => sub {
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://127.0.0.1') } 'URL with IPv4';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://::') } 'URL with IPv6';
};

subtest 'URI should have known TLDs' => sub {
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost') } 'URL without TLD';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.local') } 'URL with invalid TLD';
    dies_ok { BOM::RPC::v3::Utility::validate_uri('http://username.com.local') } 'URL with .com.invalid TLD';
};

subtest 'Healthy URL' => sub {
    lives_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com') } 'Healthy http URL';
    lives_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com.org') } 'Healthy http URL com.org';
    lives_ok { BOM::RPC::v3::Utility::validate_uri('https://localhost.com') } 'Healthy https URL';
    lives_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com/example') } 'Healthy http URL with subdir';
    lives_ok { BOM::RPC::v3::Utility::validate_uri('http://localhost.com/example/subdir') } 'Healthy http URL with two subdir';
    lives_ok { BOM::RPC::v3::Utility::validate_uri('http://نامه.com/example/subdir') } 'Healthy http URL with unicode host';
    lives_ok { BOM::RPC::v3::Utility::validate_uri('http://example.com/نامه/subdir') } 'Healthy http URL with unicode subdir';
};

done_testing();
