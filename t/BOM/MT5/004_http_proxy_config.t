use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Deep;
use Test::Exception;

use BOM::MT5::User::Async;

subtest 'HTTP proxy wrong server type' => sub {

    my $res = BOM::MT5::User::Async::_is_http_proxy_enabled_for('trash', 'p01_ts01');

    is($res, 0, 'In case of wrong server type it should return 0');

};

subtest 'HTTP proxy wrong server key' => sub {

    my $res = BOM::MT5::User::Async::_is_http_proxy_enabled_for('real', 'p03_ts03');

    is($res, 0, 'In case of wrong server key it should return 0');

};

subtest 'HTTP proxy wrong server type and key ' => sub {

    my $res = BOM::MT5::User::Async::_is_http_proxy_enabled_for('trash', 'p03_ts03');

    is($res, 0, 'In case of wrong server type and key it should return 0');

};
