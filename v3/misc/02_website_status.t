use strict;
use warnings;
use Test::More;
use JSON::MaybeUTF8 qw/decode_json_utf8/;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use Test::MockModule;
use Mojo::Redis2;
use Clone;
use BOM::Config::Chronicle;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;

#we need this because of calculating max exchange rates on currency config
populate_exchange_rates();

my $t = build_wsapi_test();
$t = $t->send_ok({json => {website_status => 1}})->message_ok;
my $res = decode_json_utf8($t->message->[1]);

my $reader = BOM::Config::Chronicle::get_chronicle_reader();
my $writer = BOM::Config::Chronicle::get_chronicle_writer();

is $res->{website_status}->{terms_conditions_version},
    $reader->get('app_settings', 'binary')->{global}->{cgi}->{terms_conditions_version},
    'terms_conditions_version should be readed from chronicle';

# Update terms_conditions_version at chronicle
my $updated_tcv = 'Version 100 ' . Date::Utility->new->date;
$writer->set('app_settings', 'binary', {global => {cgi => {terms_conditions_version => $updated_tcv}}}, Date::Utility->new);

is $reader->get('app_settings', 'binary')->{global}->{cgi}->{terms_conditions_version}, $updated_tcv, 'Chronickle should be updated';

#Test website status subscription id
my $uuid = $res->{subscription};
ok !$uuid, 'Is not subscribed (subscribe arg defaults to 0)';

$t = $t->send_ok({
        json => {
            website_status => 1,
            subscribe      => 1
        }})->message_ok;
$res = decode_json_utf8($t->message->[1]);
ok !$res->{error}, 'No error when subscribing';
ok $uuid = $res->{subscription}->{id}, 'Subscription id is returned';

$t = $t->send_ok({
        json => {
            website_status => 1,
            subscribe      => 0
        }})->message_ok;

$res = decode_json_utf8($t->message->[1]);
is $res->{subscription}, undef, 'No subscription key for non-subscribe requests.';

$t = $t->send_ok({
        json => {
            website_status => 1,
            subscribe      => 1
        }})->message_ok;
$res = decode_json_utf8($t->message->[1]);
is $res->{error}->{code}, 'AlreadySubscribed', 'Correct error for duplicate subscription';

$t = $t->send_ok({json => {forget_all => 'website_status'}})->message_ok;
$res = decode_json_utf8($t->message->[1]);

is $res->{forget_all}->[0], $uuid, 'The same id returned by forget_all';

$t = $t->send_ok({
        json => {
            website_status => 1,
            subscribe      => 0
        }})->message_ok;
$res = decode_json_utf8($t->message->[1]);
is $res->{subscription}, undef, 'No subscription key after forget_all';

$t = $t->send_ok({
        json => {
            website_status => 1,
            subscribe      => 1
        }})->message_ok;
$res = decode_json_utf8($t->message->[1]);
cmp_ok $uuid, 'ne', $res->{subscription}->{id}, 'New subscription id is issued';
$uuid = $res->{subscription}->{id};

$t = $t->send_ok({json => {forget => $uuid}})->message_ok;
$res = decode_json_utf8($t->message->[1]);
is $res->{forget}, 1, 'Successfully forgotten';

# The followind does NOT work on travis, as rpc lauched as separate process
# my $time_mock =  Test::MockModule->new('App::Config::Chronicle');
# $time_mock->mock('refresh_interval', sub { -1 });

# wait app-cconfig refresh
sleep 11;
$t = $t->send_ok({json => {website_status => 1}})->message_ok;
$res = decode_json_utf8($t->message->[1]);

is $res->{website_status}->{terms_conditions_version}, $updated_tcv, 'It should return updated terms_conditions_version';

my $ws_redis_write_config = YAML::XS::LoadFile('/etc/rmg/ws-redis.yml')->{write};

my $ws_redis_write_url = do {
    my ($host, $port, $password) = @{$ws_redis_write_config}{qw/host port password/};
    "redis://" . (defined $password ? "dummy:$password\@" : "") . "$host:$port";
};

my $shared_info  = {};
my $channel_name = "NOTIFY::broadcast::channel";
my $state_key    = "NOTIFY::broadcast::state";
my $is_on_key    = "NOTIFY::broadcast::is_on";     ### TODO: to config

### Blue master
my $redis = Mojo::Redis2->new(url => $ws_redis_write_url);
$redis->on(
    error => sub {
        my ($self, $err) = @_;
        warn "ws write redis error: $err";
    });
$redis->on(
    message => sub {
        my ($self, $msg, $channel) = @_;

        Binary::WebSocketAPI::v3::Wrapper::Streamer::send_notification($shared_info, $msg, $channel);
    });
is($redis->set($is_on_key, 1), 'OK');
$t = build_wsapi_test(
    {},
    {},
    sub {
        my ($self, $mess) = @_;
        test_schema("website_status", $mess);
    });

$t = $t->send_ok({
        json => {
            website_status => 1,
            subscribe      => 1
        }})->message_ok;

$shared_info->{echo_req} = {
    website_status => 1,
    subscribe      => 1
};
$shared_info->{c} = $t;
my $pid = fork;

die "Failed fork for testing 'ticks' WS API call: $@" unless defined $pid;
unless ($pid) {
    # disable end test of Test::Warnings in child process
    Test::Warnings->import(':no_end_test');

    sleep 1;
    for (1 .. 2) {
        $redis->publish($channel_name => '{"site_status": "up", "message": "Unit test ' . $_ . '"}');
        sleep 1;
    }
    exit;
}
sleep 2;

$t->finish_ok;

done_testing();
