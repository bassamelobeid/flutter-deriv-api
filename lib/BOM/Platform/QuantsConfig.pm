package BOM::Platform::QuantsConfig;
use strict;
use warnings;

use YAML::XS qw(LoadFile);

my $config = LoadFile('/etc/rmg/quants_config.yml');

has config => (
    is      => 'ro',
    default => sub {$config},
);

1;

