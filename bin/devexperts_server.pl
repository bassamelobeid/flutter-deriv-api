use strict;
use warnings;

use Getopt::Long;
use IO::Async::Loop;
use WebService::Async::DevExperts::Server;
use YAML::XS;
use Log::Any::Adapter;
use Path::Tiny qw(path);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

=head1 devexperts_server.pl

Runs a DevExperts simulated server instance.

=cut

GetOptions(
    'l|log=s'        => \my $log_level,
    'p|port=s'       => \my $port,
    'k|api_key=s'    => \my $api_key,
    's|api_secret=s' => \my $api_secret,
    'pid-file=s'     => \my $pid_file,     # for tests
);

path($pid_file)->spew("$$") if $pid_file;

my $config = YAML::XS::LoadFile('/etc/rmg/devexperts.yml');

$log_level  //= 'info';
$port       //= $config->{api}{port};
$api_key    //= $config->{api}{api_key};
$api_secret //= $config->{api}{api_secret};

Log::Any::Adapter->import('Stderr', log_level => $log_level);

my $loop = IO::Async::Loop->new;
$loop->add(
    my $server = WebService::Async::DevExperts::Server->new(
        addr => {
            family   => "inet",
            socktype => "stream",
            port     => $port
        },
        api_key    => $api_key,
        api_secret => $api_secret,
    ));

$server->start->get;
$loop->run;
