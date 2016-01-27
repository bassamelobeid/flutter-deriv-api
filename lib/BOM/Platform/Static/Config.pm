package BOM::Platform::Static::Config;

use strict;
use warnings;
use feature 'state';

sub get_display_languages {
    return ['EN', 'ID', 'RU', 'ES', 'FR', 'PT', 'DE', 'ZH_CN', 'PL', 'AR', 'ZH_TW', 'VI', 'IT'];
}

sub get_static_path {
    return "/home/git/binary-com/binary-static/";
}

sub get_static_url {
    return "https://static.binary.com/";
}

sub get_customer_support_email {
    return 'support@binary.com';
}

{

    sub get_config {
        return {
            binary_static_hash => Data::UUID->new->create_str(),
        };
    }
}

1;
