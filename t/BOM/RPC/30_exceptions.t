use strict;
use warnings;

use Test::More;
use Test::Warnings;

my %stats;
BEGIN {
    *DataDog::DogStatsd::Helper::stats_inc = sub {
        ++$stats{$_[0]}
    };
}
use BOM::RPC::v3::Contract;

is_deeply(\%stats, { }, 'start with no metrics');
like(warning {
    BOM::RPC::v3::Contract::_log_exception(something => 'details here')
}, qr/^Unhandled exception in something: details here/, 'saw warning');

is_deeply(\%stats, {
    'contract.exception.something' => 1
}, 'had statsd inc');
%stats = ();

like(warning {
    BOM::RPC::v3::Contract::_log_exception('invalid.component' => 'details here')
}, qr/^Invalid copmponent.*Unhandled exception in something: details here/s, 'saw both warnings on invalid component name');

is_deeply(\%stats, {
    'invalid_component' => 1
}, 'but still had relevant statsd inc');

done_testing;

