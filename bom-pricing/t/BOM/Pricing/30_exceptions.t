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
        ++$stats{$_[0]};
    };
}

use BOM::Pricing::v3::Contract;

is_deeply(\%stats, {}, 'start with no metrics');
cmp_deeply(
    [warnings { BOM::Pricing::v3::Contract::_log_exception(something => 'details here') }],
    bag(re('Unhandled exception in something: details here')),
    'saw warning'
);

is_deeply(\%stats, {'contract.exception.something' => 1}, 'had statsd inc');
%stats = ();

cmp_deeply(
    [warnings { BOM::Pricing::v3::Contract::_log_exception('invalid.component' => 'details here') }],
    bag(re('Unhandled exception in (\S+) details here'), re('invalid component passed'),),
    'saw both warnings on invalid component name'
);

cmp_deeply(\%stats, {'contract.exception.invalid_component' => 1}, 'but still had relevant statsd inc');

done_testing;

