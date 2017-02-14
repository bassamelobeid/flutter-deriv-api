use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use YAML::XS;
use Mojo::Redis2;
use JSON::XS qw | encode_json |;
if ( $#ARGV < 1 ) {
  print "Usage:\n";
  print "\t -s \t site status. up or down. up by default\n";
  print "\t -o \t Notifications turn on/off ( 1 or 0 ). 1 by default\n";
  print "\t -m \t Message ( in quotes )\n";
  print "\n Example:\n";
  print "\t".' perl clients_notify.pl -s up -o 1 -m "Take five"' . "\n";
  exit;
}

my %params = @ARGV;

$params{"-o"} //= 1;
$params{"-s"} //= 'up';

delete $params{"-o"} unless $params{"-o"} == 1    || $params{"-o"} == 0;
delete $params{"-s"} unless $params{"-s"} eq 'up' || $params{"-s"} eq 'down';

my $channel_name = "NOTIFY::broadcast::channel";
my $state_key    = "NOTIFY::broadcast::state";
my $is_on_key    = "NOTIFY::broadcast::is_on";     ### TODO: to config

print "\nRedis initiate...";
my $ws_redis_write_config = YAML::XS::LoadFile('/etc/rmg/ws-redis.yml')->{write};
my $ws_redis_write_url = do {
    my ($host, $port, $password) = @{$ws_redis_write_config}{qw/host port password/};
    "redis://" . (defined $password ? "dummy:$password\@" : "") . "$host:$port";
};

my $redis = Mojo::Redis2->new(url => $ws_redis_write_url);
$redis->on(
    error => sub {
        my ($self, $err) = @_;
        warn "ws write redis error: $err";
    });
print "Done\n";

if ( $params{"-s"} || $params{"-m"} ) {
  print "\nWrite state...";
  my $is_on_value = $params{"-o"};
  print $redis->set($is_on_key, $is_on_value) if $is_on_value;
  print "...";
  my $mess_obj = eval{ encode_json ( {
				      site_status => $params{"-s"} // "up",
				      message     => $params{"-m"} // ""
				     } ) };
  print "\nEncode JSON error: ".$@ and exit if $@;
  print $redis->set($state_key, $mess_obj);
  print "...";
  print "Done\n";

  print "\nPublish...";
  my $subscribes_count =  $redis->publish($channel_name, $mess_obj);
  print "Done\n";
  print $subscribes_count . " clients subscribed\n";
}

print "\n\nBYE!\n";
