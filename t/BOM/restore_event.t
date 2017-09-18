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
    my $dp  = Date::Utility->new('2017-06-13 00:19:59');
    my $dp2 = Date::Utility->new('2017-06-12 00:19:59');

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            events => [{
                    release_date => $dp2->epoch,
                    event_name   => 'test2',
                    symbol       => 'AUD',
                    impact       => 3,
                    source       => 'fake source'
                },
                {
                    release_date => $dp->epoch,
                    event_name   => 'test1',
                    symbol       => 'AUD',
                    impact       => 3,
                    source       => 'fake source'
                }

            ]});

    my $event_id = 'c6980571536e7a22';

    BOM::EconomicEventTool::delete_by_id($event_id);

    my $deleted_event = BOM::EconomicEventTool::_get_deleted_events();

    my $expected_delete = {
        'source'       => 'fake source',
        'symbol'       => 'AUD',
        'event_name'   => 'test2',
        'release_date' => '1497226799',
        'id'           => 'c6980571536e7a22',
        'impact'       => '3',
    };

    cmp_deeply($deleted_event->{$event_id}, $expected_delete, 'Deleted event');

    my $restore_event = BOM::EconomicEventTool::restore_by_id({id => $event_id});

    my $expected_restore = {
        'source'       => 'fake source',
        'symbol'       => 'AUD',
        'event_name'   => 'test2',
        'release_date' => '2017-06-12 00:19:59',
        'id'           => 'c6980571536e7a22',
        'impact'       => '3',
        'info'         => [],
        'new_info'     => [],
        'unlisted'     => 1,
    };

    cmp_deeply($restore_event, $expected_restore, 'restoring event ');

    my $latest_data_in_chronicle = BOM::EconomicEventTool::_get_economic_events($dp2);

    my $expected = {
        'source'       => 'fake source',
        'symbol'       => 'AUD',
        'event_name'   => 'test2',
        'release_date' => '1497226799',
        'id'           => 'c6980571536e7a22',
        'impact'       => '3',
    };

    cmp_deeply($latest_data_in_chronicle, [$expected], 'Deleted event is restored correctly');

};

done_testing();
