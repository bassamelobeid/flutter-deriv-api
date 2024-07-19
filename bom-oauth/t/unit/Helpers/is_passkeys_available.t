use strict;
use warnings;
use utf8;

use Test::More;
use Test::MockObject;

use BOM::OAuth::Helper qw(is_passkeys_available);

my $c          = Test::MockObject->new();
my %test_cases = (
    'passkeys_available=true' => {
        'cookie_key'   => 'passkeys_available',
        'cookie_value' => 'true',
        'expected'     => 1
    },
    'passkeys_available=\'true\'' => {
        'cookie_key'   => 'passkeys_available',
        'cookie_value' => '\'true\'',
        'expected'     => 0
    },
    'passkeys_available cookie is not set' => {
        'cookie_key'   => undef,
        'cookie_value' => undef,
        'expected'     => 0
    },
    'passkeys_available=false' => {
        'cookie_key'   => 'passkeys_available',
        'cookie_value' => 'false',
        'expected'     => 0
    },
    'passkeys_available cookie is not set properly' => {
        'cookie_key'   => 'passkeys_available',
        'cookie_value' => '',
        'expected'     => 0
    },
    'passkeys_available=1' => {
        'cookie_key'   => 'passkeys_available',
        'cookie_value' => '1',
        'expected'     => 0
    },
    'passkeys_available=0' => {
        'cookie_key'   => 'passkeys_available',
        'cookie_value' => '0',
        'expected'     => 0
    },
    'passkeys_available=undef' => {
        'cookie_key'   => 'passkeys_available',
        'cookie_value' => 'undef',
        'expected'     => 0
    },
    'passkeys_available=null' => {
        'cookie_key'   => 'passkeys_available',
        'cookie_value' => 'null',
        'expected'     => 0
    },
    'passkeys_available=<script>alert("XSS")</script>' => {
        'cookie_key'   => 'passkeys_available',
        'cookie_value' => '<script>alert("XSS")</script>',
        'expected'     => 0
    },
);

my $cookie_key;
my $cookie_value;
my $expected;

$c->mock(
    cookie => sub {
        return undef if !defined $cookie_key;
        return $cookie_value;
    });

subtest 'test BOM::OAuth::Helper->is_passkeys_available' => sub {
    foreach my $test_case (keys %test_cases) {
        $cookie_key   = $test_cases{$test_case}{'cookie_key'};
        $cookie_value = $test_cases{$test_case}{'cookie_value'};
        $expected     = $test_cases{$test_case}{'expected'};

        my $result = is_passkeys_available($c);
        is($result, $expected, $test_case);
    }
};

done_testing();
