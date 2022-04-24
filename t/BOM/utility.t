#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Warnings;
use Test::Exception;
use Test::MockTime;
use Date::Utility;

use BOM::Transaction::Utility;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Product::ContractFactory qw(produce_contract);

Test::MockTime::set_fixed_time(time);
my $now    = Date::Utility->new(time);
my $symbol = 'R_100';

my $args = {
    bet_type     => 'ASIANU',
    underlying   => $symbol,
    date_start   => $now,
    date_pricing => $now,
    duration     => '5t',
    currency     => 'USD',
    payout       => 10,
};

subtest 'get_pricing_ttl' => sub {
    subtest 'tick expiry contract' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, $symbol]);
        my $c = produce_contract($args);
        is BOM::Transaction::Utility::get_pricing_ttl($c->shortcode), 130, 'pricing_ttl for 5t contract';

        $args->{duration} = '1t';
        $c = produce_contract($args);
        is BOM::Transaction::Utility::get_pricing_ttl($c->shortcode), 122, 'pricing_ttl for 1t contract';
    };

    subtest 'non-tick-expiry contract' => sub {
        $args->{duration} = '1m';
        my $c = produce_contract($args);
        is BOM::Transaction::Utility::get_pricing_ttl($c->shortcode), 180, 'pricing_ttl for 1m contract';

        $args->{duration} = '1h';
        $c = produce_contract($args);
        is BOM::Transaction::Utility::get_pricing_ttl($c->shortcode), 3720, 'pricing_ttl for 1h contract';

        $args = {
            underlying   => $symbol,
            bet_type     => 'MULTUP',
            currency     => 'USD',
            multiplier   => 100,
            amount       => 100,
            date_start   => $now,
            date_pricing => $now,
            amount_type  => 'stake',
        };
        $c = produce_contract($args);
        is BOM::Transaction::Utility::get_pricing_ttl($c->shortcode), 86400, 'pricing_ttl for multiplier contract';
    };

    subtest 'invalid shortcode' => sub {
        my $shortcode = 'CALL_FRXEURCHF_50_5_MARCH_09_6_7';
        is BOM::Transaction::Utility::get_pricing_ttl($shortcode), undef, 'ttl for invalid shortcode is not calculated';

        is BOM::Transaction::Utility::get_pricing_ttl(), undef, 'get undef if shortcode is not provided';
    };
};

done_testing();
