package BOM::Platform::Static::Config;

use strict;
use warnings;

sub get_display_languages {
    return ['EN', 'ID', 'RU', 'ES', 'FR', 'PT', 'DE', 'ZH_CN', 'PL', 'AR', 'ZH_TW', 'VI', 'IT'];
}

sub get_static_url {
    return "https://static.binary.com/";
}

sub get_google_tag_manager {
    return "GTM-MZWFF7";
}

sub get_customer_support_email {
    return 'support@binary.com';
}

sub get_customer_support_telephone {
    return {
        "Canada"         => "+1 (450) 823 1002",
        "Australia"      => "+61 (02) 8294 5448",
        "Ireland"        => "+353 (0) 76 888 7500",
        "Poland"         => "+48 58 881 00 02",
        "United Kingdom" => "+44 (0) 1666 800042",
        "Germany"        => "+49 0221 98259000"
    };
}

sub get_customer_support_tollfree_numbers {
    return {
        "Australia"      => "1800 093570",
        "Indonesia"      => "0018030113641",
        "Ireland"        => "1800931084",
        "Russia"         => "8 10 8002 8553011",
        "United Kingdom" => "0800 011 9847"
    };
}

sub get_customer_support_default_telephone {
    return {"country" => "United Kingdom"};
}

sub get_customer_support_skype_helpline {
    return {
        "EN" => "binaryhelpline",
        "ID" => "binaryhelplineid",
        "RU" => "binaryhelplineru"
    };
}

1;
