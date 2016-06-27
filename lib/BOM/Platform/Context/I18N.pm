package BOM::Platform::Context::I18N;

use feature 'state';
use strict;
use warnings;

use Path::Tiny;

use BOM::Platform::Runtime;
require Locale::Maketext::Lexicon;

sub handle_for {
    my $language = shift;

    state %handles;
    $language = lc $language;
    unless (exists $handles{$language}) {
        my $translation_class = _class_for();
        $handles{$language} = ${translation_class}->get_handle($language);
    }

    return $handles{$language};
}

sub _class_for {
    state %classes;
    my $rclass = "BOM::Platform::Context::I18N::binary-com";
    $rclass =~ s/\./_/g;
    $rclass =~ s/-/_/g;
    return $rclass if $classes{$rclass};

    my $config = configs_for();
    my @where = (__LINE__ + 3, __FILE__);
    eval <<EOP;    ## no critic
#line $where[0] "$where[1]"
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
    my $config = {};

    my $locales_dir = '/home/git/binary-com/translations-websockets-api/src';
    warn("Unable to locate locales directory. Looking in $locales_dir") unless (-d $locales_dir);

    foreach my $language (@{BOM::Platform::Runtime->instance->app_config->cgi->supported_languages}) {
        my $po_file_path;
        if ($language eq 'EN') {
            $po_file_path = path($locales_dir)->child(lc $language . '.po');
        } else {
            $po_file_path = path($locales_dir)->child("locales")->child(lc $language . '.po');

        }
        $config->{$language} = [Gettext => "$po_file_path"];
    }

    $config->{_auto}   = 1;
    $config->{_decode} = 1;

    return $config;
}

1;
