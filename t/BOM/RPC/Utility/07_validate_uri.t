use strict;
use warnings;

use Test::Most;
use BOM::RPC::v3::Utility;

subtest 'URI scheme should be valid' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http:://localhost.com'), undef, 'Bad URL ::';
    isnt BOM::RPC::v3::Utility::validate_uri('http:///localhost.com'), undef, 'Bad URL //';
    # dies_ok {BOM::RPC::v3::Utility::validate_uri('http://bla∂.com')} 'Bad URL';
};

subtest 'URI scheme should be http(s)' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('//localhost.com'),     undef, 'URL without scheme';
    isnt BOM::RPC::v3::Utility::validate_uri('localhost.com'),       undef, 'URL without slash';
    isnt BOM::RPC::v3::Utility::validate_uri('ftp://localhost.com'), undef, 'URL with ftp scheme';
};

subtest 'URI should not have port' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.com:8080'),         undef, 'URL with port';
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.com:8080/example'), undef, 'URL with port and sub dir';
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.com:'),             undef, 'URL with missing port';
};

subtest 'URI should not have query' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.com?'),                     undef, 'URL with missing query';
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.com?test='),                undef, 'URL with empty query';
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.com?test=val1&test2=val2'), undef, 'URL with query';
};

subtest 'URI should not have user info' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://@localhost.com'),                  undef, 'URL with missing userinfo';
    isnt BOM::RPC::v3::Utility::validate_uri('http://username@localhost.com'),          undef, 'URL with username';
    isnt BOM::RPC::v3::Utility::validate_uri('http://username:password@localhost.com'), undef, 'URL with password';
    isnt BOM::RPC::v3::Utility::validate_uri('http://username:passwordlocalhost.com'),  undef, 'URL with password without @';
};

subtest 'URI should not have fragments' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.com#'),       undef, 'URL with missing fragment without slash';
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.com/#'),      undef, 'URL with missing fragment';
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.com/#hello'), undef, 'URL with fragment';
};

subtest 'URI should not have IP' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://127.0.0.1'), undef, 'URL with IPv4';
    isnt BOM::RPC::v3::Utility::validate_uri('http://::'),        undef, 'URL with IPv6';
};

subtest 'URI should have known TLDs' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost'),          undef, 'URL without TLD';
    isnt BOM::RPC::v3::Utility::validate_uri('http://localhost.local'),    undef, 'URL with invalid TLD';
    isnt BOM::RPC::v3::Utility::validate_uri('http://username.com.local'), undef, 'URL with .com.invalid TLD';
};

subtest 'Healthy URL' => sub {
    is BOM::RPC::v3::Utility::validate_uri('http://localhost.com'),                undef, 'Healthy http URL';
    is BOM::RPC::v3::Utility::validate_uri('http://localhost.com.org'),            undef, 'Healthy http URL com.org';
    is BOM::RPC::v3::Utility::validate_uri('https://localhost.com'),               undef, 'Healthy https URL';
    is BOM::RPC::v3::Utility::validate_uri('http://localhost.com/example'),        undef, 'Healthy http URL with subdir';
    is BOM::RPC::v3::Utility::validate_uri('http://localhost.com/example/subdir'), undef, 'Healthy http URL with two subdir';
    is BOM::RPC::v3::Utility::validate_uri('http://نامه.com/example/subdir'),  undef, 'Healthy http URL with unicode host';
    is BOM::RPC::v3::Utility::validate_uri('http://example.com/نامه/subdir'),  undef, 'Healthy http URL with unicode subdir';
};

done_testing();
