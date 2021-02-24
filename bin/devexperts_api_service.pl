use strict;
use warnings;

use Getopt::Long;
use IO::Async::Loop;
use BOM::Platform::Script::DevExpertsAPIService;
use YAML::XS;
use Log::Any::Adapter;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

=head1 devexperts_api_service.pl

Runs the DevExperts API service, that forwards HTTP requests to the DevExperts server.

=cut

# These options are described in BOM::Platform::Script::DevExpertsAPIService configure method.
GetOptions(
    'l|log=s'        => \my $log_level,
    'p|port=s'       => \my $listen_port,
    'h|api_host=s'   => \my $api_host,
    'd|api_port=s'   => \my $api_port,
    'a|api_auth=s'   => \my $api_auth,
    'k|api_key=s'    => \my $api_key,
    's|api_secret=s' => \my $api_secret,
    'u|api_user=s'   => \my $api_user,
    'w|api_pass=s'   => \my $api_pass,
);

my $config = YAML::XS::LoadFile('/etc/rmg/devexperts.yml');

$log_level   //= 'info';
$listen_port //= $config->{service}{port};
$api_host    //= $config->{api}{host};
$api_port    //= $config->{api}{port};
$api_auth    //= $config->{api}{auth};
$api_key     //= $config->{api}{api_key};
$api_secret  //= $config->{api}{api_secret};
$api_user    //= $config->{api}{user};
$api_pass    //= $config->{api}{pass};

Log::Any::Adapter->import('Stderr', log_level => $log_level);

my $loop = IO::Async::Loop->new;
$loop->add(
    my $service = BOM::Platform::Script::DevExpertsAPIService->new(
        listen_port => $listen_port,
        api_host    => $api_host,
        api_port    => $api_port,
        api_auth    => $api_auth,
        api_key     => $api_key,
        api_secret  => $api_secret,
        api_user    => $api_user,
        api_pass    => $api_pass,
    ));

$service->start->get;
$loop->run;
