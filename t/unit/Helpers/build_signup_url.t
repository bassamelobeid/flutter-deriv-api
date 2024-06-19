use strict;
use warnings;
use utf8;

use Test::More;

use BOM::OAuth::Helper qw(build_signup_url);

# Edge cases, such as invalid query parameters, case sensitivity or multiple parameters are handled by the controller itself.

# Test cases
my %test_cases = (
    'Happy path: https://oauth.deriv.com/oauth2/authorize?app_id=36218&l=fr&partnerId=abcd1234 -> https://deriv.com/fr/ctrader-signup/?app_id=36218&partnerId=abcd1234'
        => {
        'app_id'    => 36218,
        'lang'      => 'fr',
        'partnerId' => 'abcd1234',
        'expected'  => 'https://deriv.com/fr/ctrader-signup/?app_id=36218&partnerId=abcd1234'
        },
    'Happy path: https://oauth.deriv.com/oauth2/authorize?app_id=16929 -> https://deriv.com/en/signup' => {
        'app_id'    => 16929,
        'lang'      => 'en',                           # default language, which is set in the controller if no language is provided
        'partnerId' => '',
        'expected'  => 'https://deriv.com/en/signup'
    },
    'Happy path: https://oauth.deriv.com/oauth2/authorize?app_id=16929&l=fr -> https://deriv.com/fr/signup' => {
        'app_id'    => 16929,
        'lang'      => 'fr',
        'partnerId' => '',
        'expected'  => 'https://deriv.com/fr/signup'
    },
    'Happy path: https://oauth.deriv.com/oauth2/authorize?app_id=36218&l=fr -> https://deriv.com/fr/ctrader-signup/?app_id=36218' => {
        'app_id'    => 36218,
        'lang'      => 'fr',
        'partnerId' => '',
        'expected'  => 'https://deriv.com/fr/ctrader-signup/?app_id=36218'
    },
    'Happy path: https://oauth.deriv.com/oauth2/authorize?app_id=37228&l=fr -> https://deriv.com/academy-signup' => {
        'app_id'    => 37228,
        'lang'      => 'fr',
        'partnerId' => '',
        'expected'  => 'https://deriv.com/academy-signup'
    },
);

subtest 'test BOM::OAuth::Helper->build_signup_url' => sub {
    foreach my $test_case (keys %test_cases) {
        my $params = {
            'app_id'    => $test_cases{$test_case}->{app_id},
            'lang'      => $test_cases{$test_case}->{lang},
            'partnerId' => $test_cases{$test_case}->{partnerId},
        };

        my $result   = build_signup_url($params);
        my $expected = $test_cases{$test_case}{'expected'};
        is($result, $expected, "Test case: $test_case");
    }
};

done_testing();
