package BOM::Platform::QuantsConfig;
use strict;
use warnings;

use YAML::XS qw(LoadFile);

my $config = LoadFile('/home/git/regentmarkets/bom-platform/config/quants_config.yml');

sub config {
    return $config;
};

1;

