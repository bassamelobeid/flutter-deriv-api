#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

my $args = {
    underlying => 'frxGBPUSD',
    bet_type   => 'CALL',
    barrier    => 'S0P',
    date_start => time,
    currency   => 'USD',
    payout     => 10,
};

subtest 'before 2-july' => sub {
    $args->{date_expiry} = Date::Utility->new('2016-07-01');
    my $c = produce_contract($args);
    is $c->base_commission, 0.2, '20% commission on contract expirying before 2-Jul';
};

subtest 'after 2-july' => sub {
    $args->{date_expiry} = Date::Utility->new('2016-07-04');
    my $c = produce_contract($args);
    is $c->base_commission, 0.05, '5% commission on contract expirying after 2-Jul';
};
