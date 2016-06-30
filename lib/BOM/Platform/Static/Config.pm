package BOM::Platform::Static::Config;

use strict;
use warnings;
use feature 'state';

use YAML::XS qw(LoadFile);

use constant quants => LoadFile('/home/git/regentmarkets/bom-platform/config/quants_config.yml');

sub get_static_path {
    return "/home/git/binary-com/binary-static/src/";
}

sub get_static_url {
    return "https://www.binary.com/";
}

sub get_allowed_broker_codes {
    return ['MX', 'MF', 'MLT', 'CR', 'JP', 'VRTC', 'VRTJ', 'FOG'];
}

1;
