package BOM::Platform::Context::I18N;

use feature 'state';
use strict;
use warnings;
use BOM::Platform::Runtime;
use Path::Tiny;
use Carp;

sub handle_for {
    my $language = shift;
    my $website  = shift || BOM::Platform::Runtime->instance->website_list->default_website;
    my $version  = shift || BOM::Platform::Runtime->instance->website_list->default_website->config->get('static.version');

    state %handles;
    $language = lc $language;
    my $handle_key = $website->static_host . '_' . $version . '_' . $language;
    unless (exists $handles{$handle_key}) {
        my $translation_class = _class_for($website, $version);
        $handles{$handle_key} = ${translation_class}->get_handle($language);
    }

    return $handles{$handle_key};
}

sub _class_for {
    my $website = shift;
    my $version = shift;

    state %classes;
    my $rclass = "BOM::Platform::Context::I18N::" . $website->static_host . "_$version";
    $rclass =~ s/\./_/g;
    $rclass =~ s/-/_/g;
    return $rclass if $classes{$rclass};

    my $config = configs_for($website, $version);
    eval <<EOP;    ## no critic
package $rclass;
use parent 'BOM::Platform::Context::I18N::Base';
sub import_lexicons {
    my \$class = shift;
    Locale::Maketext::Lexicon->import(\@_);
}
EOP
    ${rclass}->import_lexicons($config);
    $classes{$rclass}++;
    return $rclass;
}

sub configs_for {
    my $website = shift;
    my $version = shift;
    my $config  = {};

    my $locales_dir = path($website->static_path)->child('/config/locales/');
    carp("Unable to locate locales directory. Looking in $locales_dir") unless (-d $locales_dir);

    foreach my $language (@{BOM::Platform::Runtime->instance->app_config->cgi->supported_languages}) {
        my $po_file_path = path($locales_dir)->child(lc $language . '.po');
        $config->{$language} = [Gettext => "$po_file_path"];
    }

    $config->{_auto}   = 1;
    $config->{_decode} = 1;

    return $config;
}

1;
