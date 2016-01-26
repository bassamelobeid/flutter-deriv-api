package BOM::Platform::Static::Config;

use strict;
use warnings;

sub get_display_languages {
    return ['EN', 'ID', 'RU', 'ES', 'FR', 'PT', 'DE', 'ZH_CN', 'PL', 'AR', 'ZH_TW', 'VI', 'IT'];
}

sub get_static_url {
    return "https://static.binary.com/";
}

sub get_customer_support_email {
    return 'support@binary.com';
}

1;
