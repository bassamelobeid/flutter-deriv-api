package BOM::Platform::Locale;

use strict;
use warnings;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request localize);
use utf8;    # to support source-embedded country name strings in this module
use Locale::SubCountry;

sub getLanguageOptions {
    my $options = '';

    foreach my $lang_code (@{BOM::Platform::Runtime->instance->app_config->cgi->allowed_languages}) {
        my $lang_string = _lang_display_name($lang_code);

        #Make english as the default language.
        if ($lang_code eq 'EN') {
            $options .= "<option value=$lang_code selected>$lang_string</option>\n";
        } else {
            $options .= "<option value=$lang_code>$lang_string</option>\n";
        }
    }

    return $options;
}

sub translate_salutation {
    my $provided = shift;

    my %translated_titles = (
        MS   => localize('Ms'),
        MISS => localize('Miss'),
        MRS  => localize('Mrs'),
        DR   => localize('Dr'),
        MR   => localize('Mr'),
        PROF => localize('Prof'),
    );

    return $translated_titles{uc $provided} || $provided;
}

sub language_selector {
    my $currentLanguage   = request()->language;
    my $allowed_languages = get_display_languages();

    my $template_args = {};
    $template_args->{options} = [
        map { {code => $_, text => $allowed_languages->{$_}, value => uc($_), selected => (uc($currentLanguage) eq uc($_) ? 1 : 0),} }
            keys %{$allowed_languages}];

    my $html;
    BOM::Platform::Context::template->process('global/language_form.html.tt', $template_args, \$html)
        || die BOM::Platform::Context::template->error;
    return $html;
}

sub get_display_languages {
    my @allowed_langs = split(',', BOM::Platform::Context::request()->website->config->get('display_languages'));
    my $al = {};
    map { $al->{$_} = _lang_display_name($_) } @allowed_langs;
    return $al;
}

sub _lang_display_name {
    my $iso_code = shift;

    my %lang_code_name = (
        AR    => 'Arabic',
        DE    => 'Deutsch',
        ES    => 'Español',
        FR    => 'Français',
        EN    => 'English',
        ID    => 'Bahasa Indonesia',
        JA    => '日本語',
        PL    => 'Polish',
        PT    => 'Português',
        RU    => 'Русский',
        VI    => 'Vietnamese',
        ZH_CN => '简体中文',
        ZH_TW => '繁體中文',
        IT    => 'Italiano'
    );

    $iso_code = defined($iso_code) ? uc $iso_code : '';
    return $lang_code_name{$iso_code} || $iso_code;
}

sub generate_residence_countries_list {
    my $residence_countries_list = [{
            value => '',
            text  => localize('Select Country')}];

    foreach my $country_selection (
        sort { $a->{translated_name} cmp $b->{translated_name} }
        map { +{code => $_, translated_name => BOM::Platform::Runtime->instance->countries->localized_code2country($_, request()->language)} }
        BOM::Platform::Runtime->instance->countries->all_country_codes
        )
    {
        my $country_code = $country_selection->{code};
        my $country_name = $country_selection->{translated_name};
        if (length $country_name > 26) {
            $country_name = substr($country_name, 0, 26) . '...';
        }

        my $option = {
            value => $country_code,
            text  => $country_name
        };

        if (BOM::Platform::Runtime->instance->restricted_country($country_code)) {
            $option->{disabled} = 'DISABLED';
        } elsif (request()->country_code eq $country_code) {
            $option->{selected} = 'selected';
        }
        push @$residence_countries_list, $option;
    }

    return $residence_countries_list;
}

sub get_state_option {
    my $country_code = shift or return;

    $country_code = uc $country_code;
    state %codes;
    unless (%codes) {
        %codes = Locale::SubCountry::World->code_full_name_hash;
    }
    return unless $codes{$country_code};

    my @options = ({
            value => '',
            text  => localize('Please select')});

    my $country = Locale::SubCountry->new($country_code);
    if ($country and $country->has_sub_countries) {
        my %name_map = $country->full_name_code_hash;
        push @options, map { {value => $name_map{$_}, text => $_} }
            sort $country->all_full_names;
    }
    return \@options;
}

1;