use strict;
use warnings;

use Test::Most;
use Test::MockTime qw/:all/;
use JSON;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types; 

my $time      = Date::Utility->new;
my $test_date = Date::Utility->new('2012-03-14 07:00:00');
set_fixed_time($test_date->epoch);

my $t = build_mojo_test();
my ($req_storage, $res, $start, $end);

# as these validations are in websocket so test it
subtest 'validations' => sub {
    $req_storage = {
        ticks_history => 'blah',
        granularity   => 10,
        end           => 'latest'
    };

    $t->send_ok({json => $req_storage});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code}, 'InvalidGranularity', "Correct error code for granularity";
    delete $req_storage->{granularity};

    $t->send_ok({json => $req_storage});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    is_deeply($res->{echo_req}, $req_storage, 'Echo request is the same');

    $req_storage->{style} = 'sample';
    $t->send_ok({json => $req_storage});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code}, 'InputValidationFailed', "Correct error code for invalid style";
};

subtest 'call_ticks_history' => sub {
    my $start = $test_date->minus_time_interval('7h');
    my $end   = $start->plus_time_interval('1m');
    $req_storage = {
        ticks_history => 'frxUSDJPY',
        end           => $end->epoch,
        start         => $start->epoch,
        style         => 'ticks',
        subscribe     => 1
    };

    my $is_open = create_underlying('frxUSDJPY')->calendar->is_open_at($time);

    $t->send_ok({json => $req_storage});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);

    # If it is not open, this call will return error message.
    if ($is_open) {
        is $res->{msg_type}, 'history', 'Result type should be history';

        $req_storage->{count} = 10;
        $t->send_ok({json => $req_storage});
        $t   = $t->message_ok;
        $res = decode_json($t->message->[1]);
        is $res->{error}->{code}, 'AlreadySubscribed', 'Already subscribed';
    } else {

        is $res->{msg_type}, 'ticks_history', 'Result type should be history';
        is $res->{error}->{code}, 'MarketIsClosed', 'The market is presently closed';
    }

};

done_testing();
