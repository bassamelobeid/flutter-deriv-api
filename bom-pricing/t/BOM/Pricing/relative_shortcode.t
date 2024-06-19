#!/usr/bin/env perl
use strict;
use warnings;

use Date::Utility;
use Test::Exception;
use Test::MockTime;
use Test::More;
use Test::Warnings qw(warnings);

use BOM::Pricing::v3::Utility;

my $create_relative_shortcode = \&BOM::Pricing::v3::Utility::create_relative_shortcode;

my $params = {
    barrier       => 'S0P',
    contract_type => 'CALL',
    duration      => 5,
    duration_unit => 'm',
    symbol        => 'R_10',
};

Test::MockTime::set_absolute_time('2019-09-10T08:00:00Z');

subtest 'relative_shortcode' => sub {
    is($create_relative_shortcode->($params), 'CALL_R_10_0_300_S0P_0', 'relative duration');

    $params->{date_start} = Date::Utility->new('2019-09-10 10:00:00')->epoch;
    is($create_relative_shortcode->($params), 'CALL_R_10_7200F_300_S0P_0', 'forward starting');

    $params->{date_expiry} = Date::Utility->new('2019-09-10 11:00:00')->epoch;
    is($create_relative_shortcode->($params), 'CALL_R_10_7200F_3600F_S0P_0', 'forward starting, date expiry');

    delete $params->{date_start};
    is($create_relative_shortcode->($params), 'CALL_R_10_0_10800F_S0P_0', 'date expiry');

    delete $params->{date_expiry};
    $params->{contract_type} = 'TOUCH';
    $params->{barrier}       = '+1.270';
    is($create_relative_shortcode->($params), 'TOUCH_R_10_0_300_S1270P_0', 'single relative barrier');

    $params->{contract_type} = 'EXPIRYMISS';
    $params->{barrier2}      = -1.280;
    is($create_relative_shortcode->($params), 'EXPIRYMISS_R_10_0_300_S1270P_S-1280P', 'dual relative barrier');

    my $spot = '7942.653';
    is($create_relative_shortcode->($params, $spot), 'EXPIRYMISS_R_10_0_300_S1270P_S-1280P', 'relative barrier ignores current spot');

    $params->{barrier}  = '7977.083';
    $params->{barrier2} = '7907.113';
    is($create_relative_shortcode->($params, $spot), 'EXPIRYMISS_R_10_0_300_S34430P_S-35540P', 'dual absolute barrier');

    $params->{contract_type} = 'TOUCH';
    $params->{barrier}       = '7977.083';
    delete $params->{barrier2};
    is($create_relative_shortcode->($params, $spot), 'TOUCH_R_10_0_300_S34430P_0', 'single absolute barrier');

    $params->{duration_unit} = 't';
    is($create_relative_shortcode->($params, $spot), 'TOUCH_R_10_0_5T_S34430P_0', 'tick duration');
};

Test::MockTime::restore_time();

done_testing;
