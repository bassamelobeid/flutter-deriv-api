use strict;
use warnings;

use Getopt::Long;
use IO::Async::Loop;
use WebService::Async::DevExperts::DxWeb::Server;
use YAML::XS;
use Log::Any::Adapter;
use Path::Tiny qw(path);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

=head1 devexperts_server.pl

Runs a DevExperts simulated server instance.

=cut

GetOptions(
    'l|log=s'    => \my $log_level,
    'p|port=s'   => \my $port,
    'e|env=s'    => \my $env,
    'pid-file=s' => \my $pid_file,    # for tests
);

path($pid_file)->spew("$$") if $pid_file;

my $config = YAML::XS::LoadFile('/etc/rmg/devexperts.yml');

$log_level //= 'info';
$env       //= 'demo';
$port      //= $config->{servers}{$env}{port};

Log::Any::Adapter->import('Stderr', log_level => $log_level);

my $loop = IO::Async::Loop->new;
$loop->add(
    my $server = WebService::Async::DevExperts::DxWeb::Server->new(
        addr => {
            family   => "inet",
            socktype => "stream",
            port     => $port
        }));

$server->start->get;
$loop->run;
