#!perl

use Test::Most;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;
use Net::EmptyPort qw(empty_port);

my $port = empty_port;
@ENV{qw/TEST_DICTATOR_HOST TEST_DICTATOR_PORT/} = ('127.0.0.1', $port);

{    # shamelessly borrowed from BOM::Feed

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
        my ($symbol, $start, $end, $cb) = @args{qw(symbol start_time end_time callback)};
        $self->{"$cb"}{timer} = AE::timer 0.1, 1, sub {
            $cb->({
                epoch => time,
                quote => "42"
            });
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

use BOM::Platform::SessionCookie;

build_test_R_50_data();
my $t = build_mojo_test();

my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'sy@regentmarkets.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'sy@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR2002';

$t = $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
my $tick = decode_json($t->message->[1]);
ok $tick->{tick}->{id};
ok $tick->{tick}->{quote};
ok $tick->{tick}->{epoch};
test_schema('ticks', $tick);

# stop tick
$t = $t->send_ok({json => {forget => $tick->{tick}->{id}}})->message_ok;
my $forget = decode_json($t->message->[1]);
ok $forget->{forget};
test_schema('forget', $forget);

$t = $t->send_ok({
        json => {
            "proposal"      => 1,
            "amount"        => "10",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "symbol"        => "R_50",
            "duration"      => "2",
            "duration_unit" => "m"
        }})->message_ok;
my $proposal = decode_json($t->message->[1]);
ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};
test_schema('proposal', $proposal);

sleep 1;
$t = $t->send_ok({
        json => {
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}}});

## skip proposal until we meet buy
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    note explain $res;
    next if $res->{msg_type} eq 'proposal';

    ok $res->{buy};
    ok $res->{buy}->{contract_id};
    ok $res->{buy}->{purchase_time};

    test_schema('buy', $res);
    last;
}

$t = $t->send_ok({json => {forget => $proposal->{proposal}->{id}}})->message_ok;
$forget = decode_json($t->message->[1]);
note explain $forget;
is $forget->{forget}, 0, 'buying a proposal deletes the stream';

$t = $t->send_ok({json => {portfolio => 1}})->message_ok;
my $portfolio = decode_json($t->message->[1]);
ok $portfolio->{portfolio}->{contracts};
ok $portfolio->{portfolio}->{contracts}->[0]->{contract_id};
test_schema('portfolio', $portfolio);

## test portfolio and sell
$t = $t->send_ok({
        json => {
            proposal_open_contract => 1,
            contract_id            => $portfolio->{portfolio}->{contracts}->[0]->{contract_id},
        }});
$t = $t->message_ok;
my $res = decode_json($t->message->[1]);

if (exists $res->{proposal_open_contract}) {
    ok $res->{proposal_open_contract}->{id};
    test_schema('proposal_open_contract', $res);
}

$t->finish_ok;
kill 9, $pid;

done_testing();
