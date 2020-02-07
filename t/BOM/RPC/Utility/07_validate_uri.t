use strict;
use warnings;

use Test::Most;
use BOM::RPC::v3::Utility;
use utf8;

subtest 'URI scheme should be valid' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http:://example.com'),                 undef, 'Bad URL ::';
    isnt BOM::RPC::v3::Utility::validate_uri('http:///example.com'),                 undef, 'Bad URL //';
    isnt BOM::RPC::v3::Utility::validate_uri('http://username:passwordexample.com'), undef, 'URL with password without @';
    isnt BOM::RPC::v3::Utility::validate_uri('//example.com'),                       undef, 'URL without scheme';
};

subtest 'URI scheme should be valid' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('example.com'),       undef, 'URL without slash';
    isnt BOM::RPC::v3::Utility::validate_uri('a@2://example.com'), undef, 'URL with invalid scheme';
};

subtest 'URI should not have port' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com:8080'),         undef, 'URL with port';
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com:8080/example'), undef, 'URL with port and sub dir';
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com:'),             undef, 'URL with missing port';
};

subtest 'URI should not have query' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com?'),                     undef, 'URL with missing query';
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com?test='),                undef, 'URL with empty query';
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com?test=val1&test2=val2'), undef, 'URL with query';
};

subtest 'URI should not have user info' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://@example.com'),                  undef, 'URL with missing userinfo';
    isnt BOM::RPC::v3::Utility::validate_uri('http://username@example.com'),          undef, 'URL with username';
    isnt BOM::RPC::v3::Utility::validate_uri('http://username:password@example.com'), undef, 'URL with password';
};

subtest 'URI should not have fragments' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com#'),       undef, 'URL with missing fragment without slash';
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com/#'),      undef, 'URL with missing fragment';
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com/#hello'), undef, 'URL with fragment';
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

subtest 'Unencoded Unicode is not allowed' => sub {
    isnt BOM::RPC::v3::Utility::validate_uri('http://نامه.com/example/subdir'), undef, 'Unicode in host';
    isnt BOM::RPC::v3::Utility::validate_uri('http://example.com/نامه/subdir'), undef, 'Unicode in path';
};

subtest 'Healthy URL' => sub {
    is BOM::RPC::v3::Utility::validate_uri('http://example.com'),                          undef, 'Healthy http URL';
    is BOM::RPC::v3::Utility::validate_uri('http://example.com.org'),                      undef, 'Healthy http URL com.org';
    is BOM::RPC::v3::Utility::validate_uri('https://example.com'),                         undef, 'Healthy https URL';
    is BOM::RPC::v3::Utility::validate_uri('http://example.com/example'),                  undef, 'Healthy http URL with subdir';
    is BOM::RPC::v3::Utility::validate_uri('http://example.com/example/subdir'),           undef, 'Healthy http URL with two subdir';
    is BOM::RPC::v3::Utility::validate_uri('http://xn--c1yn36f.com/'),                     undef, 'Healthy punycode URL';
    is BOM::RPC::v3::Utility::validate_uri('http://example.com/%D9%86%D8%A7%D9%85%D9%87'), undef, 'Healthy encoded Unicode subdir';
    is BOM::RPC::v3::Utility::validate_uri('app://example.com'),                           undef, 'Healthy URL having a custom scheme';
    is BOM::RPC::v3::Utility::validate_uri('my-scheme+v0.2://example.com'),                undef, 'Healthy URL having another custom scheme';
};

done_testing();
