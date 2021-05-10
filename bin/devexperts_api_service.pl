use strict;
use warnings;

use Getopt::Long;
use IO::Async::Loop;
use BOM::Platform::Script::DevExpertsAPIService;
use YAML::XS;
use Log::Any::Adapter;
use Path::Tiny qw(path);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

=head1 devexperts_api_service.pl

Runs the DevExperts API service, which forwards HTTP requests to the DevExperts server.

=cut

my %args;

GetOptions(
    'l|log=s'     => \my $log_level,
    'p|port=s'    => \$args{listen_port},
    'demo_host=s' => \$args{demo_host},
    'demo_port=s' => \$args{demo_port},
    'demo_user=s' => \$args{demo_user},
    'demo_pass=s' => \$args{demo_pass},
    'real_host=s' => \$args{real_host},
    'real_port=s' => \$args{real_port},
    'real_user=s' => \$args{real_user},
    'real_pass=s' => \$args{real_pass},
    'pid-file=s'  => \my $pid_file,         # for tests
);

path($pid_file)->spew("$$") if $pid_file;

$log_level //= 'info';
Log::Any::Adapter->import('Stderr', log_level => $log_level);

my $config = YAML::XS::LoadFile('/etc/rmg/devexperts.yml');

$args{listen_port} //= $config->{service}{port};
$args{demo_host}   //= $config->{servers}{demo}{host};
$args{demo_port}   //= $config->{servers}{demo}{port};
$args{demo_user}   //= $config->{servers}{demo}{user};
$args{demo_pass}   //= $config->{servers}{demo}{pass};
$args{real_host}   //= $config->{servers}{real}{host};
$args{real_port}   //= $config->{servers}{real}{port};
$args{real_user}   //= $config->{servers}{real}{user};
$args{real_pass}   //= $config->{servers}{real}{pass};

my $loop = IO::Async::Loop->new;
$loop->add(my $service = BOM::Platform::Script::DevExpertsAPIService->new(%args));

$service->start->get;
$loop->run;
