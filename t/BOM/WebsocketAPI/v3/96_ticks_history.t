use strict;
use warnings;

use Test::Most;
use Test::MockTime qw/:all/;
use JSON;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

my $now = Date::Utility->new('2012-03-14 07:00:00');
set_fixed_time($now->epoch);

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
    #is $res->{echo_req}->{granularity}, 60, 'Should set default granularity if it is empty';
    is_deeply($res->{echo_req}, $req_storage, 'Echo request is the same');

    $req_storage->{style} = 'sample';
    $t->send_ok({json => $req_storage});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code}, 'InputValidationFailed', "Correct error code for invalid style";
};

subtest 'call_ticks_history' => sub {
    my $start = $now->minus_time_interval('7h');
    my $end   = $start->plus_time_interval('1m');

    $req_storage = {
        ticks_history => 'frxUSDJPY',
        end           => $end->epoch,
        start         => $start->epoch,
        style         => 'ticks',
        subscribe     => 1
    };

    $t->send_ok({json => $req_storage});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{msg_type}, 'history', 'Result type should be history';

    $req_storage->{count} = 10;
    $t->send_ok({json => $req_storage});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code}, 'AlreadySubscribed', 'Already subscribed';
};

done_testing();
