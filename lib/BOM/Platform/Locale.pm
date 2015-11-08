package BOM::Platform::Locale;

use strict;
use warnings;
use feature "state";
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

        # to be removed later - JP
        if (BOM::Platform::Runtime->instance->restricted_country($country_code) or $country_code eq 'jp') {
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

sub error_map {
    return {
        'email unverified'      => localize('Your email address is unverified.'),
        'no residence'          => localize('Your account has no country of residence.'),
        'invalid'               => localize('Sorry, account opening is unavailable.'),
        'invalid residence'     => localize('Sorry, our service is not available for your country of residence.'),
        'invalid UK postcode'   => localize('Postcode is required for UK residents.'),
        'invalid PO Box'        => localize('P.O. Box is not accepted in address.'),
        'invalid DOB'           => localize('Your date of birth is invalid.'),
        'duplicate email'       => localize(
            'Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site. If you have forgotten the password of your existing account, please <a href="[_1]">try our password recovery tool</a> or contact customer service.',
            request()->url_for('/user/lost_password')
        ),
        'duplicate name DOB'    => localize(
            'Sorry, you seem to already have a real money account with us. Perhaps you have used a different email address when you registered it. For legal reasons we are not allowed to open multiple real money accounts per person. If you don\'t remember your account with us, please <a href="[_1]">contact us</a>.',
            request()->url_for('contact')
        ),
        'too young'             => localize('Sorry, you are too young to open an account.'),
        'show risk disclaimer'  => localize('Please agree to the risk disclaimer before proceeding.'),
        'insufficient score'    => localize(
            'Unfortunately your answers to the questions above indicate that you do not have sufficient financial resources or trading experience to be eligible to open a trading account at this time.'
        ),
    };
}

1;
