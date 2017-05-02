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

#Getting all PRICER_STATUS keys from redis along with their pricing timing.
my %pricers_on_ip;
for (@keys) {
    my %entry = @{decode_json($redis->get($_))};
    $pricers_on_ip{$entry{ip}} = [] unless exists $pricers_on_ip{$entry{ip}};
    $entry{'diff'}       = time - $entry{time};
    $entry{'key'}        = $_;
    #reconsructed hash that has the ip address of the pricer as key and the stats (including calculated time difference) of each fork that it has as an array.
    $pricers_on_ip{$entry{ip}}[$entry{fork_index}] = \%entry;
}

#Getting all pricers ips that are currently registered as valid working pricers.
my $ip_list = {};
$ip_list = {%$ip_list, get_ips($_)} for qw/blue green/;

#find out which pricers that has been terminated and delete their keys from redis. (this will work as garbage collector)
my @ips_not_in_list = grep { not exists $ip_list->{$_} } keys %pricers_on_ip;

for my $ip (@ips_not_in_list) {
    print "pricer_daemon with an ip: $ip is an orphan\n";
    #delete key from redis.
    for (@{$redis->scan_all(MATCH => "PRICER_STATUS::$ip*")}) {
        $redis->del($_);
    }
}

#Comparing and reporting the stats to datadog.
for my $ip (keys %$ip_list) {
    #check if the pricer is registered and doing work
    if (exists $pricers_on_ip{$ip}) {
        #looping through the array of forks.
        foreach my $e (@{$pricers_on_ip{$ip}}) {
            #send the time of the last activity of each fork to datadog and create a monitor there.
            DataDog::DogStatsd::Helper::stats_timing("pricer_daemon.forks.last_active.$e->{'fork_index'}",
                $e->{'diff'}, {tags => ['tag:' . $e->{'ip'}]});
            #to be printed to log.
			send_pd("pricer_daemon with an ip: $e->{'ip'} has a fork with PID: $e->{'pid'} thats not doing any work for $e->{'diff'}seconds.", "trigger", "PricerStatus_$e->{'ip'}_$e->{'fork_index'}")
				if $e->{'diff'} > 60 ;
	
        }
    } else {
		DataDog::DogStatsd::Helper::stats_inc('pricer_daemon.failed.count', {tags => ['tag:' . $ip]});
        #the pricer is registered, but its not doing any work.
        #send PD alert
        send_pd("pricer_daemon with an ip: $ip is not doing any pricing while its set to be a pricer in env: $ip_list->{$ip}", "trigger", "PricerStatus_$ip");
    }
}

#get the list of registered pricers ips.
#this subrotine is used in production environment.
sub get_ips {
    my $env = shift;
    my $ua = Mojo::UserAgent->new;
    my $res;
    my $tx = $ua->get("http://172.30.0.60/$env")->success;
    die unless $tx;
    my $b = $tx->body;
    $b =~ s/\r//gm;
    chomp $b;
    return {map { ; $_ => $env } split /\n/, $b};
}

#This subrotine is used for testing, in development mode only.
sub get_ips_dev {
	my $env = shift;
    my %ip_list;
    open FILE, "/tmp/" . $env . "_ip_list" or die $!;
    while (my $line = <FILE>) {
        chomp($line);
        $line =~ s/\r//;
        $ip_list{"$line"} = $env;
    }
    close FILE;
    return %ip_list;
}

#send PagerDuty alert, im trying to set an incident key so we can resolve it, within the code also. but it needs more testing.
sub send_pd {
    my ($error_msg, $type, $incident_key) = @_;

    my $PD_serviceKey = $ENV{'PD_SERVICE_KEY'};
    my $PD_apiKey     = $ENV{'PD_API_KEY'};
    my $PD_enabled    = $ENV{'PD_ENABLED'};

	warn $error_msg;

	return unless $PD_enabled; 

    my $ua            = Mojo::UserAgent->new;
    my $tx = $ua->post(
    	'https://events.pagerduty.com/generic/2010-04-15/create_event.json' => {
        "Authorization" => "Token token=$PD_apiKey",
        "Content-type"  => "application/json",
        "Accept"        => "application/vnd.pagerduty+json;version=2"
        } => json => {
        	"service_key" => $PD_serviceKey,
            "event_type"  => $type,
            "description" => $error_msg,
			"incident_key" => $incident_key
        });
    if (my $res = $tx->success) { return 0; }
    else {
        warn $tx->error->{code};
    }
}
