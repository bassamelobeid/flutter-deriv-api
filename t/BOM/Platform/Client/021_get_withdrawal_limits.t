#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More qw( no_plan );
use Test::MockTime;
use Test::Exception;
use Math::Round qw( round );

use BOM::Platform::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::Account;

# create client object
my $client;
lives_ok { $client = BOM::Platform::Client->new({loginid => 'CR0026'}) } 'Can create client object.';
my $withdrawal_limits = $client->get_withdrawal_limits();

is($withdrawal_limits->{'frozen_free_gift'},         0,   'USD frozen_free_gift is 0');
is($withdrawal_limits->{'free_gift_turnover_limit'}, 500, 'USD free_gift_turnover_limit is 500');

Test::MockTime::restore_time();
