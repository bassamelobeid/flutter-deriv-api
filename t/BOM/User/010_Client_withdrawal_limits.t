#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More qw( no_plan );
use Test::MockTime;
use Test::Exception;
use Math::Round qw( round );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;

# create client object
my $client;
lives_ok { $client = BOM::User::Client->new({loginid => 'CR0026'}) } 'Can create client object.';
my $withdrawal_limits = $client->get_withdrawal_limits();

is($withdrawal_limits->{'frozen_free_gift'},         0,   'USD frozen_free_gift is 0');
is($withdrawal_limits->{'free_gift_turnover_limit'}, 500, 'USD free_gift_turnover_limit is 500');

subtest 'CR0027.' => sub {
    plan tests => 2;

    my $client            = BOM::User::Client->new({loginid => 'CR0027'});
    my $withdrawal_limits = $client->get_withdrawal_limits();

    is($withdrawal_limits->{'frozen_free_gift'},         0,   'USD frozen_free_gift is 0');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 250, 'USD free_gift_turnover_limit is 250');
};

subtest 'CR0028.' => sub {
    plan tests => 2;

    my $client            = BOM::User::Client->new({loginid => 'CR0028'});
    my $withdrawal_limits = $client->get_withdrawal_limits();

    cmp_ok($withdrawal_limits->{'frozen_free_gift'}, '==', 20, 'USD frozen_free_gift is 20');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 500, 'USD free_gift_turnover_limit is 500');
};

my $login_id = 'MLT0017';

# create client object
Test::Exception::lives_ok { $client = BOM::User::Client->new({loginid => $login_id}) } "Can create client object $login_id";

is($client->broker, 'MLT', 'client broker is MLT');

Test::MockTime::set_absolute_time('2008-05-10T07:02:44Z');

$withdrawal_limits = $client->get_withdrawal_limits();

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
