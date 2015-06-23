#!/usr/bin/perl

use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Platform::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $login_id = 'MLT0017';

# create client object
my $client;
Test::Exception::lives_ok { $client = BOM::Platform::Client->new({loginid => $login_id}) } "Can create client object $login_id";

is($client->broker, 'MLT', 'client broker is MLT');

Test::MockTime::set_absolute_time('2008-05-10T07:02:44Z');

my $withdrawal_limits = $client->get_withdrawal_limits();

my $result = {
    'max_withdrawal'         => 9930,
    frozen_free_gift         => 0,
    free_gift_turnover_limit => 0,
};

is_deeply($withdrawal_limits, $result, 'check non-authenticated MLT withdrawal limit');

$withdrawal_limits = $client->get_withdrawal_limits();

$result = {
    'max_withdrawal'           => 9930,
    'frozen_free_gift'         => 0,
    'free_gift_turnover_limit' => 0,
};

is_deeply($withdrawal_limits, $result, 'check authenticated MLT withdrawal limit');

Test::MockTime::restore_time();
