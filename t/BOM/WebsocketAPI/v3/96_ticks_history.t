use strict;
use warnings;

use Test::Most;
use Test::MockTime qw/:all/;
use JSON;
use Date::Utility;
use File::Temp;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::FeedTestDatabase qw/:init/;
use BOM::Feed::Buffer::TickFile;
use BOM::Feed::Populator::InsertTicks;

my $now = Date::Utility->new('2012-03-14 07:00:00');
set_fixed_time($now->epoch);

subtest 'Initialization' => sub {
    lives_ok {
        my ($fill_start, $populator, @ticks, $fh);
        my $work_dir = File::Temp->newdir();
        my $buffer = BOM::Feed::Buffer::TickFile->new(base_dir => "$work_dir");

        # Insert R_100 data ticks
        $fill_start = $now->minus_time_interval('1d7h');
        $populator  = BOM::Feed::Populator::InsertTicks->new({
            symbols            => [qw/ R_100 /],
            last_migrated_time => $fill_start,
            buffer             => $buffer,
        });
        open($fh, "<", "/home/git/regentmarkets/bom-test/feed/combined/frxUSDJPY/13-Apr-12.fullfeed") or die $!;
        @ticks = <$fh>;
        close $fh;
        foreach my $i (0 .. 1) {
            $populator->insert_to_db({
                ticks  => \@ticks,
                date   => $fill_start->plus_time_interval("${i}d"),
                symbol => 'R_100',
            });
        }

        # Insert frxUSDJPY data ticks
        BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/14-Mar-12.dump');
    }
    'Setup ticks';
};

my $t = build_mojo_test();
my ($req, $res, $start, $end);

subtest 'validations' => sub {
    $req = {
        ticks_history => 'blah',
        granularity   => 10,
        end           => 'latest'
    };

    $t->send_ok({json => $req});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code}, 'InvalidGranularity', "Correct error code for granularity";
    delete $req->{granularity};

    $t->send_ok({json => $req});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code},    'InvalidSymbol',       "Correct error code for invalid symbol";
    is $res->{error}->{message}, 'Symbol blah invalid', "Corrent error message fro invalid symbol";
};

subtest 'call_ticks_history' => sub {
    my $start = $now->minus_time_interval('7h');
    my $end   = $start->plus_time_interval('1m');

    $req = {
        ticks_history => 'frxUSDJPY',
        end           => $end->epoch,
        start         => $start->epoch,
        style         => 'ticks'
    };

    $t->send_ok({json => $req});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    note explain $res;
    is $res->{msg_type}, 'history', 'Result type should be history';
    is scalar(@{$res->{history}->{times}}),  47, 'It should return all trading times between start and end';
    is scalar(@{$res->{history}->{prices}}), 47, 'It should return all trading price between start and end';

    $req->{count} = 10;
    $t->send_ok({json => $req});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    note explain $res;
    is scalar(@{$res->{history}->{prices}}), 10, 'It should return expected count';
    is $res->{history}->{times}->[-1], $end->epoch, 'Last entry should match end epoch';
};

done_testing();
