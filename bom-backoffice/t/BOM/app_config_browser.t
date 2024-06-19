use strict;
use warnings;

use Test::More;

use BOM::Config::Runtime;
use BOM::Backoffice::PlackHelpers qw( check_browser_version );

=head2 valid browser user agents
    Some example browsers user agent which we consider as valid browsers to use the app
=cut

my $valid_user_agents = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.135 Safari/537.36 Edge/12.24",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.4280.135 Safari/537.36 Edge/12.24",
    "Mozilla/5.0 (X11; CrOS x86_64 8172.45.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.64 Safari/537.36",
    "Mozilla/5.0 (X11; CrOS x86_64 8172.45.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.2704.64 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_2) AppleWebKit/601.3.9 (KHTML, like Gecko) Version/9.0.2 Safari/601.3.9",
    "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.111 Safari/537.36",
    "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.2526.111 Safari/537.36",
    "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:15.0) Gecko/20100101 Firefox/15.0.1",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.140 Safari/537.36 Edge/17.17134",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.3282.140 Safari/537.36 Edge/17.17134",
    "Mozilla/5.0 (Windows NT 6.3; Trident/7.0; rv:11.0) like Gecko",
    "Mozilla/5.0 (Windows NT 10.0; WOW64; Trident/7.0; .NET4.0C; .NET4.0E; .NET CLR 2.0.50727; .NET CLR 3.0.30729; .NET CLR 3.5.30729; MAARJS; rv:11.0) like Gecko",
    "Mozilla/5.0 (Windows NT 6.3; rv:36.0) Gecko/20100101 Firefox/36.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:62.0) Gecko/20100101 Firefox/62.0",
    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html",
    "Chrome/",
    12345
];

=head2 Empty BOM::Config::Runtime->instance->app_config->system->browser->minimum_supported_chrome_version
    Some example browsers user agent which we consider as invalid Chrome browsers to use the app
=cut

ok(check_browser_version(undef, $valid_user_agents->[0]),
    qq{VALID - Undefine BOM::Config::Runtime->instance->app_config->system->browser->minimum_supported_chrome_version});
ok(check_browser_version("", $valid_user_agents->[0]),
    qq{VALID - Empty BOM::Config::Runtime->instance->app_config->system->browser->minimum_supported_chrome_version});

=head2 invalid browser user agents
    Some example browsers user agent which we consider as invalid Chrome browsers to use the app
=cut

my $invalid_user_agents = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/42.0.2311.135 Safari/537.36 Edge/12.246",
    "Mozilla/5.0 (X11; CrOS x86_64 8172.45.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.64 Safari/537.36",
    "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/47.0.2526.111 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/64.0.3282.140 Safari/537.36 Edge/17.17134"
];

foreach my $test (@$valid_user_agents) {
    ok(check_browser_version(BOM::Config::Runtime->instance->app_config->system->browser->minimum_supported_chrome_version, $test),
        qq{VALID - $test});
}

foreach my $test (@$invalid_user_agents) {
    ok(!check_browser_version(BOM::Config::Runtime->instance->app_config->system->browser->minimum_supported_chrome_version, $test),
        qq{INVALID - $test});
}

done_testing();
