#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Platform::RedisReplicated;
use DataDog::DogStatsd::Helper;
use JSON::XS qw/decode_json/;
use Data::Dumper;
use Date::Utility;
use Time::HiRes ();
use Mojo::UserAgent;
use DataDog::DogStatsd::Helper;

my $redis = BOM::Platform::RedisReplicated::redis_pricer;

my @keys = sort @{
    $redis->scan_all(
        MATCH => 'PRICER_STATUS::*',
        COUNT => 20000
    )};

#Getting all PRCER_STATUS keys from redis along with their pricing timing.
my %entries;
for (@keys) {
    my %entry = @{decode_json($redis->get($_))};
    $entries{$entry{ip}} = [] unless exists $entries{$entry{ip}};
    $entry{'diff'}       = time - $entry{time};
    $entry{'key'}        = $_;
    #reconsructed hash that has the ip address of the pricer as key and the stats (including calculated time difference) of each fork that it has as an array.
    $entries{$entry{ip}}[$entry{fork_index}] = \%entry;
}

#Getting all pricers ips that are currently registered as valid working pricers.
my $ip_list = {};
$ip_list = {%$ip_list, get_ips($_)} for qw/blue green/;

#find out which pricers that has been terminated and delete their keys from redis. (this will work as garbage collector)
my @ips_not_in_list = grep { not exists $ip_list->{$_} } keys %entries;

for (@ips_not_in_list) {
    print "pricer_daemon with an ip: $_ is an orphan\n";
    #delete key from redis.
    for (@{$redis->scan_all(MATCH => "PRICER_STATUS::$_*")}) {
        $redis->del("$_");
    }
}

#Comparing and reporting the stats to datadog.
for (keys %$ip_list) {
    #check if the pricer is registered and doing work
    if (exists $entries{$_}) {
        #looping through the array of forks.
        foreach my $e (@{$entries{$_}}) {
            #send the time of the last activity of each fork to datadog and create a monitor there.
            DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.forks.last_active',
                $e->{'diff'}, {tags => ['tag:' . $e->{'ip'}, 'pid:' . $e->{'pid'}]});
            #to be printed to log.
            print "pricer_daemon service in $e->{'ip'} ENV: $ip_list->{$_}  with fork PID: $e->{'pid'} last pricing before $e->{'diff'} seconds.\n";
        }
    } else {
        #the pricer is registered, but its not doing any work.
        print "pricer_daemon with an ip: $_ is not doing any pricing while its set to be a pricer in env: $ip_list->{$_}\n";
        #send PD alert
        send_pd("pricer_daemon with an ip: $_ is not doing any pricing while its set to be a pricer in env: $ip_list->{$_}", "trigger", "");
    }
}

#get the list of registered pricers ips.
sub get_ips {
    my $env = shift;
    #for development
    my %ip_list;
    open FILE, "/tmp/" . $env . "_ip_list" or die $!;
    while (my $line = <FILE>) {
        chomp($line);
        $line =~ s/\r//;
        $ip_list{"$line"} = $env;
    }
    close FILE;
    return %ip_list;
    #for prod
    my $ua = Mojo::UserAgent->new;
    my $res;
    my $tx = $ua->get("http://172.30.0.60/$env")->success;
    die unless $tx;
    my $b = $tx->body;
    $b =~ s/\r//gm;
    chomp $b;
    return {map { ; $_ => $env } split /\n/, $b};
}

#send PagerDuty alert, im trying to set an incident key so we can resolve it, within the code also. but it needs more testing.
sub send_pd {
    my ($error_msg, $type, $incident_key) = @_;
    my $ua            = Mojo::UserAgent->new;
    my $PD_serviceKey = $ENV{'PD_SERVICE_KEY'};
    my $PD_apiKey     = $ENV{'PD_API_KEY'};
    my $PD_enabled    = $ENV{'PD_ENABLED'};

    if ($PD_enabled) {
        my $tx = $ua->post(
            'https://events.pagerduty.com/generic/2010-04-15/create_event.json' => {
                "Authorization" => "Token token=$PD_apiKey",
                "Content-type"  => "application/json",
                "Accept"        => "application/vnd.pagerduty+json;version=2"
                } => json => {
                "service_key" => "$PD_serviceKey",
                "event_type"  => "$type",
                "description" => "$error_msg",
                #"incident_key" => "$incident_key"
                });
        if (my $res = $tx->success) { print $res->body }
        else {
            warn $tx->error->{code};
        }
    }
}
