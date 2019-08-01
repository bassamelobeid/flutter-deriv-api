#!perl

use strict;
use warnings;
use Test::More (tests => 14);
use Test::Warnings;
use Test::Exception;
use BOM::Database::DataMapper::MyAffiliates;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);

my $myaff_data_mapper;

lives_ok {
    $myaff_data_mapper = BOM::Database::DataMapper::MyAffiliates->new({
        'broker_code' => 'FOG',
        'operation'   => 'collector',
    });
}
'Expect to initialize the myaffilaites data mapper';

my $activities;
$activities = $myaff_data_mapper->get_clients_activity({'date' => Date::Utility->new('2011-03-09')});

cmp_ok($activities->{'MX1001'}->{'withdrawals'},        '==', 100,          'Check if activity withdrawals is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'deposits'},           '==', 4200,         'Check if activity deposits is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'pnl'},                '==', 0,            'Check if activity pnl is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'turnover_others'},    '==', 0,            'Check if activity turnover_others is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'turnover_intradays'}, '==', 0,            'Check if turnover_intradays factors is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'first_funded_date'},  'eq', '2011-03-09', 'Check if activity first_funded_date is correct for myaffiliate');

$activities = $myaff_data_mapper->get_clients_activity({'date' => Date::Utility->new('2017-03-09')});

cmp_ok($activities->{'MX1001'}->{'withdrawals'},        '==', 0,            'Check if activity withdrawals is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'deposits'},           '==', 0,            'Check if activity deposits is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'pnl'},                '==', 0,            'Check if activity pnl is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'turnover_others'},    '==', 0,            'Check if activity turnover_others is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'turnover_intradays'}, '==', 75,           'Check if turnover_intradays factors is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'first_funded_date'},  'eq', '2011-03-09', 'Check if activity first_funded_date is correct for myaffiliate');
