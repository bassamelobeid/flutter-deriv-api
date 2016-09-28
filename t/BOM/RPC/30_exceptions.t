use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warnings qw(warnings);

my %stats;
BEGIN {
    require DataDog::DogStatsd::Helper;
    no warnings 'redefine';
    *DataDog::DogStatsd::Helper::stats_inc = sub {
        ++$stats{$_[0]}
    };
}

use BOM::RPC::v3::Contract;

is_deeply(\%stats, { }, 'start with no metrics');
cmp_deeply(
    [ warnings { BOM::RPC::v3::Contract::_log_exception(something => 'details here') } ],
    bag(qr/^Unhandled exception in something: details here/),
    'saw warning'
);

is_deeply(\%stats, {
    'contract.exception.something' => 1
}, 'had statsd inc');
%stats = ();

cmp_deeply(
    [ warnings { BOM::RPC::v3::Contract::_log_exception('invalid.component' => 'details here') } ],
    bag(qr/^Invalid component.*Unhandled exception in invalid_component: details here/s),
    'saw both warnings on invalid component name'
);

is_deeply(\%stats, {
    'invalid_component' => 1
}, 'but still had relevant statsd inc');

done_testing;

