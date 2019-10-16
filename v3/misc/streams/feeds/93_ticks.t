use strict;
use warnings;
use Test::More;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::Warnings qw/ warning /;
use Encode;
use JSON::MaybeXS;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Config::RedisReplicated;
use File::Temp;
use Date::Utility;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $json = JSON::MaybeXS->new;
for my $symbol (qw/R_50 R_100/) {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            epoch      => Date::Utility->new->epoch,
            quote      => 100
        },
        0
    );
}

sub _create_tick {    #creates R_50 tick in redis channel DISTRIBUTOR_FEED::R_50
    my ($i, $symbol) = @_;
    $i      ||= 700;
    $symbol ||= 'R_50';
    my $ohlc_sample =
        '60:7807.4957,7811.9598,7807.1055,7807.1055;120:7807.0929,7811.9598,7806.6856,7807.1055;180:7793.6775,7811.9598,7793.5814,7807.1055;300:7807.0929,7811.9598,7806.6856,7807.1055;600:7807.0929,7811.9598,7806.6856,7807.1055;900:7789.5519,7811.9598,7784.1465,7807.1055;1800:7789.5519,7811.9598,7784.1465,7807.1055;3600:7723.5128,7811.9598,7718.4277,7807.1055;7200:7723.5128,7811.9598,7718.4277,7807.1055;14400:7743.3676,7811.9598,7672.4463,7807.1055;28800:7743.3676,7811.9598,7672.4463,7807.1055;86400:7743.3676,7811.9598,7672.4463,7807.1055;';

    my $payload = {
        symbol => $symbol,
        epoch  => int(time),
        quote  => $i,
        ask    => $i - 1,
        bid    => $i + 1,
        ohlc   => $ohlc_sample,
    };
    BOM::Config::RedisReplicated::redis_write()->publish("DISTRIBUTOR_FEED::$symbol", Encode::encode_utf8($json->encode($payload)));
}

my $t = build_wsapi_test();

my ($res, $ticks);

my $pid = fork;
die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    # disable end test of Test::Warnings in child process
    Test::Warnings->import(':no_end_test');

    sleep 1;
    for (1 .. 4) {
        _create_tick(700 + $_, 'R_50');
        _create_tick(700 + $_, 'R_100');
        sleep 1;
    }
    exit;
}

subtest 'ticks' => sub {

    # Should pass even if subscribe is a string, not integer
    $t->send_ok({
            json => {
                ticks     => 'R_50',
                subscribe => "1"
            }})->message_ok;
    $res = $json->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, undef, 'Should pass validation though string';

    ok my $id = $res->{tick}->{id}, 'There is a subscription id';
    is $res->{subscription}->{id}, $id, 'The same subscription->id';

    # will fail because subscribe should only be 1
    $t->send_ok({
            json => {
                ticks     => 'R_50',
                subscribe => 2
            }})->message_ok;
    $res = $json->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, 'InputValidationFailed', 'Should return InputValidationFailed error';
    is $res->{error}->{message}, 'Input validation failed: subscribe', 'Should return ticks validation error';

    $t->send_ok({json => {ticks => ['R_50', 'R_100']}});

    $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
    $res = $json->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, 'AlreadySubscribed', 'Should return already subscribed error';
    is $res->{error}->{message}, 'You are already subscribed to R_50', 'Should return already subscribed error';

    my $res = $t->await::forget_all({forget_all => 'ticks'});
    $t->send_ok({
            json => {
                ticks     => 'R_12312312',
                subscribe => 1
            }})->message_ok;
    $res = $json->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, 'InvalidSymbol', 'Should return invalid symbol error';
};

subtest 'ticks_forget_one_sub' => sub {

    sleep 1;
    my $res = $t->await::forget_all({forget_all => 'ticks'});

    my $req1 = {
        "ticks_history" => "R_50",
        "granularity"   => 60,
        "style"         => "candles",
        "count"         => 1,
        "end"           => "latest",
        "subscribe"     => 1,
    };
    my $req2 = {
        "ticks_history" => "R_50",
        "style"         => "ticks",
        "count"         => 1,
        "end"           => "latest",
        "subscribe"     => 1,
    };

    $res = $t->await::candles($req1);
    ok my $id1 = $res->{subscription}{id}, 'There is a subscription id';

    $res = $t->await::ohlc;
    cmp_ok $res->{msg_type}, 'eq', 'ohlc', "Recived ohlc response ok";
    is $res->{ohlc}{id}, $id1, "Subscription id ok";
    is $res->{subscription}->{id}, $id1, 'The same subscription->id';

    $res = $t->await::history($req2);
    cmp_ok $res->{msg_type}, 'eq', 'history', "Recived tick history response ok";
    my $id2 = $res->{subscription}->{id};
    ok $id2, 'Second subscription id is ok';

    $res = $t->await::forget({forget => $id1});
    cmp_ok $res->{forget}, '==', 1, "One subscription deleted ok";

    $res = $t->await::tick;
    cmp_ok $res->{msg_type}, 'eq', 'tick', "Second supscription is ok";
    is $res->{subscription}->{id}, $id2, 'Expected subscription id';
    is $res->{tick}->{id},         $id2, 'The same tick id';

};

subtest 'ticks_history_fail_rpc' => sub {

    my $res = $t->await::forget_all({forget_all => 'ticks'});
    {
        my $mock_rpc = Test::MockModule->new('MojoX::JSON::RPC::Client');
        $mock_rpc->mock(
            'call',
            sub {
                my ($a, $b, $c, $d) = @_;
                use Data::Dumper::Concise;
                &$d($a, undef);
            });
        my $req2 = {
            "ticks_history" => "R_50",
            "style"         => "ticks",
            "count"         => 1,
            "end"           => "latest",
            "req_id"        => 100,
            "subscribe"     => 1,
        };
        my $warning = warning {    #callback throws a warning on bad rpc response
            $res = $t->await::ticks_history($req2);
        };

        like($warning, qr\^WrongResponse\, "warning thrown on bad RPC result");
        cmp_ok $res->{error}->{message}, 'eq', 'Sorry, an error occurred while processing your request.',
            "Recived tick history error when RPC failed";
    }

# If the RPC response fails any subscription created in the call should be canceled and we should be able to try again with out needing to forget.

    my $req3 = {
        "ticks_history" => "R_50",
        "style"         => "ticks",
        "count"         => 1,
        "end"           => "latest",
        "req_id"        => 100,
        "subscribe"     => 1,
    };
    $res = $t->await::history($req3);

    cmp_ok $res->{msg_type}, 'eq', 'history', "Received tick history error when RPC failed";

};

$t->finish_ok;

done_testing();
