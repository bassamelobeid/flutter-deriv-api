use strict;
use warnings;
use Test::More;
use Test::Deep;
use BOM::Test::Customer;
use BOM::Event::Actions::P2P;
use BOM::User::Utility;
use RedisDB;
use JSON::MaybeUTF8 qw(decode_json_utf8);

my $service_contexts  = BOM::Test::Customer::get_service_contexts();
my $connection_config = BOM::Config::redis_p2p_config->{p2p}{read};
my $redis             = RedisDB->new(
    host => $connection_config->{host},
    port => $connection_config->{port},
    ($connection_config->{password} ? ('password' => $connection_config->{password}) : ()));

subtest 'subscribe to one country' => sub {
    my $channel = join q{::} => ('NOTIFY', 'P2P_SETTINGS', 'ID');
    $redis->subscribe($channel);
    $redis->get_reply;

    my $expected_response = BOM::User::Utility::get_p2p_settings(country => 'id');

    BOM::Event::Actions::P2P::settings_updated({affected_countries => ['id']}, $service_contexts);
    my (undef, $published_channel, $message) = $redis->get_reply->@*;
    is $published_channel, $channel, "message published to correct channel";
    cmp_deeply decode_json_utf8($message), $expected_response, 'correct response';

    BOM::Event::Actions::P2P::settings_updated({affected_countries => ['za']}, $service_contexts);
    ok !$redis->reply_ready, 'no message published because no active subscribers';

    $redis->unsubscribe($channel);
    BOM::Event::Actions::P2P::settings_updated({affected_countries => ['id']}, $service_contexts);
    ok !$redis->reply_ready, 'no message published because no active subscribers';

    $redis->get_all_replies;

};

subtest 'subscribe to multiple countries' => sub {
    $redis->subscribe(join q{::} => ('NOTIFY', 'P2P_SETTINGS', $_)) foreach qw/ID ZA BR/;
    $redis->get_reply for (0 .. 2);
    BOM::Event::Actions::P2P::settings_updated({affected_countries => ['id', 'za']}, $service_contexts);

    my %recieved_messages;
    while ($redis->reply_ready) {
        my (undef, $published_channel, $message) = $redis->get_reply->@*;
        $recieved_messages{$published_channel} = $message;
    }

    ok !$recieved_messages{'NOTIFY::P2P_SETTINGS::br'}, 'no message published for br because no event emitted for br';

    cmp_deeply decode_json_utf8($recieved_messages{"NOTIFY::P2P_SETTINGS::${\uc($_)}"}),
        BOM::User::Utility::get_p2p_settings(country => $_), "expected response for $_"
        foreach qw/id za/;

    $redis->unsubscribe;
    $redis->get_all_replies;

};

done_testing();

