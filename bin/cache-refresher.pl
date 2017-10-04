#!/etc/rmg/bin/perl

# This script is used to listen published redis event on
# 'app_settings::binary' channel, re-calculate heavy cache data
# (offerings at now) and set it in redis.
#
# This is needed to prevent every individual script to do
# recalculate cache and update it in redis.

use strict;
use warnings;
use 5.010;
no indirect;

use Algorithm::Backoff;
use JSON::XS;
use LandingCompany::Offerings qw(reinitialise_offerings);
use Mojo::IOLoop;
use Mojo::Redis2;
use Time::HiRes qw/sleep/;
use Try::Tiny;
use YAML::XS qw/LoadFile/;

use BOM::Platform::Chronicle;

STDOUT->autoflush(1);

sub extract_offerings_config {
    my $data = shift;
    # follows the logic in BOM::Platform::Runtime::get_offerings_config
    my $config = {
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),

    };
    $config->{suspend_trading}        = $data->{global}->{system}->{suspend}->{trading};
    $config->{suspend_trades}         = $data->{global}->{quants}->{underlyings}->{suspend_trades};
    $config->{suspend_buy}            = $data->{global}->{quants}->{underlyings}->{suspend_buy};
    $config->{suspend_contract_types} = $data->{global}->{quants}->{features}->{suspend_contract_types};

    $config->{disabled_markets} = $data->{global}->{quants}->{markets}->{disabled};
    return $config;
}

my $chronicle_config = LoadFile('/etc/rmg/chronicle.yml');

my $host = $chronicle_config->{read}->{host};
my $port = $chronicle_config->{read}->{port};
my $url  = "redis://$host:$port";

my $redis;
my $offering_config_digest;
my $backoff = Algorithm::Backoff->new(
    min => 0.1,
    max => 10,
);
my $last_updated = 0;
my $started      = 0;
while (!$started) {
    my $delay = $backoff->next_value;
    sleep($delay);
    try {
        $redis = Mojo::Redis2->new(url => $url);

        print "loading current settings from redis\n";
        my $settings = $redis->get('app_settings::binary');
        $settings = decode_json($settings);

        print "settings loaded, refreshing offerings due to $0 start\n";
        my $offerings_config = extract_offerings_config($settings);
        reinitialise_offerings($offerings_config);
        $offering_config_digest = LandingCompany::Offerings::_get_config_key($offerings_config);
        print "offerings has been refreshed, digest = $offering_config_digest\n";
        $started      = 1;
        $last_updated = time;
    }
    catch {
        warn("Startup error: $_");
        if ($backoff->limit_reached) {
            warn("Alarm! Too many service failures");
        }
    };

}

$redis->on(
    error => sub {
        my ($redis, $err) = @_;
        warn "redis error: $err";
        Mojo::IOLoop->stop;
    });

$redis->on(
    message => sub {
        my ($reids, $message, $channel) = @_;
        print("received new config\n");

        my $data   = decode_json($message);
        my $config = extract_offerings_config($data);

        my $new_digest = LandingCompany::Offerings::_get_config_key($config);
        if ($new_digest ne $offering_config_digest) {
            print("Found new offerings config, refreshing, digest: $new_digest\n");
            reinitialise_offerings($config);
            print("Offerings refreshing complete\n");
            $offering_config_digest = $new_digest;
            $last_updated           = time;
        } else {
            print("No need to refresh offerings, last updated: $last_updated\n");
        }
        return;
    });

$redis->subscribe(
    ["app_settings::binary"],
    sub {
        print("Subscribed\n");
    });

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
print("Exiting\n");
