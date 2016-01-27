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

sub get_config {
    state $config = {};
    unless (exists $config->{binary_js_hash}) {
        my $config_file = path(BOM::Platform::Static::Config::get_static_path())->child('config.json');
        my $config_json = File::Slurp::read_file($config_file);
        my $config_data = decode_json($config_json);

        $config->{binary_js_hash}  = $config_data->{binary_js_hash};
        $config->{binary_css_hash} = $config_data->{binary_css_hash};
    }
    return $config;
}

1;
