#!/usr/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Test::More;
use Test::Warn;
use Test::Deep qw( cmp_deeply );
use Date::Utility;
use BOM::EconomicEventTool;
use Data::Dumper;

subtest 'restore event' => sub {
    my $dp     = Date::Utility->new('2017-06-13 00:19:59');
    my $dp2    = Date::Utility->new('2017-06-12 00:19:59');


BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            events => [{
                    release_date => $dp2->epoch,
                    event_name   => 'test2',
                    symbol       => 'FAKE1',
                    impact       => 1,
                    source       => 'fake source'
                },
                {
                    release_date => $dp->epoch,
                    event_name   => 'test2',
                    symbol       => 'FAKE2',
                    impact       => 3,
                    source       => 'fake source'
                }

]});

my $event_id = '120f93141ebcdead';

BOM::EconomicEventTool::delete_by_id($event_id);

my $deleted_event = BOM::EconomicEventTool::_get_deleted_events();

my $expected = {
          'source' => 'fake source',
          'symbol' => 'FAKE1',
          'event_name' => 'test2',
          'release_date' => 1497226799,
          'id' => '120f93141ebcdead',
          'impact' => '1'
        };

cmp_deeply($deleted_event->{$event_id}, $expected, 'Deleted event');

my $restore_event = BOM::EconomicEventTool::restore_by_id({ id => $event_id});

cmp_deeply($restore_event, $expected, 'restoring event ');    

my $latest_data_in_chronicle = BOM::EconomicEventTool::_get_economic_events($dp2);

cmp_deeply($latest_data_in_chronicle, [$expected], 'Deleted event is restored correctly');

};

done_testing();
