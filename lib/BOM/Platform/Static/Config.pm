package BOM::Platform::Static::Config;

use strict;
use warnings;
use feature 'state';

use YAML::XS qw(LoadFile);

use constant quants => LoadFile('/home/git/regentmarkets/bom-platform/config/quants_config.yml');


sub get_allowed_broker_codes {
    return ['MX', 'MF', 'MLT', 'CR', 'JP', 'VRTC', 'VRTJ', 'FOG'];
}

1;
