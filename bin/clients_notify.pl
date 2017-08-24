use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use YAML::XS;
use Mojo::Redis2;
use JSON::XS qw | encode_json |;
use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);

STDOUT->autoflush(1);

GetOptions(
    's|status=s'              => \my $status,
    'o|notifications-on=i'    => \my $is_on,
    'm|message=s'             => \my $message,
    'h|help'                  => \my $help,
);

my $show_help = $help;
die <<"EOF" if ( not ( $status || defined $is_on || $message ) || $show_help);
usage: $0 OPTIONS
These options are available:
  -s, --status                   Site status. up or down. up by default
  -o, --notifications-on         Notifications turn on/off ( 1 or 0 ). 1 by default
  -m, --message                  Message ( in quotes )
  -h, --help                     Show this message.
EOF

if (!$is_on || $is_on != 0 && $is_on != 1) {
    $is_on = 1;
}

if ( !$status || $status ne 'up' && $status ne 'down' ) {
    $status = 'up';
}

my $channel_name = "NOTIFY::broadcast::channel";
my $state_key    = "NOTIFY::broadcast::state";
my $is_on_key    = "NOTIFY::broadcast::is_on";     ### TODO: to config

my $ws_redis_master_config = YAML::XS::LoadFile('/etc/rmg/ws-redis.yml')->{write};
my $ws_redis_master_url = do {
    my ($host, $port, $password) = @{$ws_redis_master_config}{qw/host port password/};
    "redis://" . (defined $password ? "dummy:$password\@" : "") . "$host:$port";
};

my $ws_redis_master = Mojo::Redis2->new(url => $ws_redis_master_url);
$ws_redis_master->on(
    error => sub {
        my ($self, $err) = @_;
        warn "ws write redis error: $err";
    });

if ( $status || $message ) {
    my $is_on_value = $is_on;
    print $ws_redis_master->set($is_on_key, $is_on_value), "\n" if $is_on_value;

    my $mess_obj = encode_json ( {
        site_status => $status  // "up",
        message     => $message // ""
    } );
    print $ws_redis_master->set($state_key, $mess_obj), "\n";

    my $subscribes_count =  $ws_redis_master->publish($channel_name, $mess_obj);
    print $subscribes_count . " workers subscribed\n";
}
