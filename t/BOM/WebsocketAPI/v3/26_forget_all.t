use strict;
use warnings;
use Test::More;
use Data::Dumper;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;
use Net::EmptyPort qw(empty_port);

my $port = empty_port;
@ENV{qw/TEST_DICTATOR_HOST TEST_DICTATOR_PORT/} = ('127.0.0.1', $port);

{   # shamelessly borrowed from BOM::Feed

    # mock BOM::Feed::Dictator::Cache
    package BOM::Feed::Dictator::MockCache;
    use strict;
    use warnings;
    use AnyEvent;

    sub new {
        my $class = shift;
        return bless {@_}, $class;
    }

    sub add_callback {
        my ($self, %args) = @_;
        my ($symbol, $start, $end, $cb) =
            @args{qw(symbol start_time end_time callback)};
        $self->{"$cb"}{timer} = AE::timer 0.1, 1, sub {
            $cb->({epoch => time, quote => "42"});
        };
    }
}

my $pid = fork;
unless ($pid) {
    require BOM::Feed::Dictator::Server;
    my $srv = BOM::Feed::Dictator::Server->new(
        port  => $port,
        cache => BOM::Feed::Dictator::MockCache->new,
    );

    alarm 20;
    AE::cv->recv;
    exit 0;
}

build_test_R_50_data();

my $t               = build_mojo_test();
my (@ticks, %ticks, @proposals, %proposals);

for (1..25) {
    $t->send_ok({json => {ticks => 'R_50'}});
    while (1) {
        $t->message_ok;
        # diag $t->message->[1];
        my $m = JSON::from_json $t->message->[1];
        is $m->{msg_type}, 'tick', 'got msg_type tick';
        ok $m->{tick}->{id}, 'got id';
        unless (exists $ticks{$m->{tick}->{id}}) {
            push @ticks, $m;
            $ticks{$m->{tick}->{id}} = $m;
            last;
        }
    }
}

for (1..25) {
    $t->send_ok({
        json => {
            "proposal"      => 1,
            "amount"        => "10",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "symbol"        => "R_50",
            "duration"      => "2",
            "duration_unit" => "m"
        }});
    while (1) {
        $t->message_ok;
        # diag $t->message->[1];
        my $m = JSON::from_json $t->message->[1];
        next if $m->{msg_type} eq 'tick';
        is $m->{msg_type}, 'proposal', 'got msg_type proposal';
        ok $m->{proposal}->{id}, 'got id';
        unless (exists $proposals{$m->{proposal}->{id}}) {
            push @proposals, $m;
            $proposals{$m->{proposal}->{id}} = $m;
            last;
        }
    }
}

alarm 10;
diag 'triggering resource error now';

my $emsg;
my $lastid;
$t->send_ok({json => {ticks => 'R_50'}});
while (1) {
    $t->message_ok;
    # diag $t->message->[1];
    my $m = JSON::from_json $t->message->[1];
    if ($m->{msg_type} eq 'tick') {
        ok $m->{tick}->{id}, 'got id';
        unless (exists $ticks{$m->{tick}->{id}}) {
            push @ticks, $m;
            $ticks{$m->{tick}->{id}} = $m;
            $lastid = $m->{tick}->{id};
            last if $emsg;
        }
    } else {
        $emsg = $m;
        last if $lastid;
    }
}

my $dropped_id = $emsg->{error}->{details}->{id};
ok $emsg->{error}, 'got an error message';
is $emsg->{error}->{code}, 'EndOfTickStream', 'EndOfTickStream';
is $dropped_id, $ticks[0]->{tick}->{id}, 'first opened stream has been canceled';
shift @ticks;
delete $ticks{$dropped_id};

# at this point we have 25 tick streamer and 25 proposals. And we have proven that any new addition
# triggers an error. Now, we'll forget them and see that we can add 50 streams again.

$t->send_ok({json => {forget_all => 'ticks'}});
while (1) {
    $t = $t->message_ok;
    my $m = JSON::from_json($t->message->[1]);
    next if $m->{msg_type} eq 'tick' or $m->{msg_type} eq 'proposal';

    ok $m->{forget_all};
    is scalar(@{$m->{forget_all}}), 25;
    test_schema('forget_all', $m);

    is_deeply [sort @{$m->{forget_all}}], [sort map {$_->{tick}->{id}} @ticks],
        'forgotten ids meet expectations';

    last;
}

$t->send_ok({json => {forget_all => 'proposal'}});
while (1) {
    $t = $t->message_ok;
    my $m = JSON::from_json($t->message->[1]);
    next if $m->{msg_type} eq 'tick' or $m->{msg_type} eq 'proposal';

    ok $m->{forget_all} or diag explain $m;
    is scalar(@{$m->{forget_all}}), 25;
    test_schema('forget_all', $m);

    is_deeply [sort @{$m->{forget_all}}], [sort map {$_->{proposal}->{id}} @proposals],
        'forgotten ids meet expectations';

    last;
}

$t->finish_ok;
kill 9, $pid;

done_testing();
