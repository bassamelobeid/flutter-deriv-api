package BOM::Platform::Account::Virtual;

use strict;
use warnings;

use Try::Tiny;

use LandingCompany::Registry;

use BOM::User;
use BOM::User::Password;
use BOM::Config::Runtime;
use BOM::Platform::Context qw(localize request);

sub create_account {
    my $args                   = shift;
    my $details                = $args->{details};
    my $email                  = lc $details->{email};
    my $password               = $details->{client_password} ? BOM::User::Password::hashpw($details->{client_password}) : '';
    my $residence              = $details->{residence};
    my $date_first_contact     = $details->{date_first_contact};
    my $brand_name             = $details->{brand_name} // request()->brand->name;
    my $brand_country_instance = Brands->new(name => $brand_name)->countries_instance;

    if (BOM::Config::Runtime->instance->app_config->system->suspend->new_accounts) {
        return {error => 'invalid'};
    } elsif (BOM::User->new(email => $email)) {
        return {error => 'duplicate email'};
    } elsif ($residence && $brand_country_instance->restricted_country($residence)) {
        return {error => 'invalid residence'};
    }
    # set virtual company if residence is provided otherwise use brand name to infer the broker code
    my $default_virtual = $brand_name eq 'champion' ? 'champion-virtual' : 'virtual';
    return {error => 'InvalidBrand'} unless grep { $brand_name eq $_ } LandingCompany::Registry::get($default_virtual)->allowed_for_brands->@*;

    #return error if date_first_contact is in future or invalid
    # date_first_contact is used by marketing to record when users first touched a binary.com site.
    # it must be passed in in GMT time to match the server timezone.
    if (defined $date_first_contact) {
        my $valid_date = try {
            my $contact_date = Date::Utility->new($date_first_contact);
            #Any dates older than 30 days set to 30 days old
            if ($contact_date->is_before(Date::Utility->today->minus_time_interval('30d'))) {
                $date_first_contact = Date::Utility->today->minus_time_interval('30d')->date_yyyymmdd;
            } elsif ($contact_date->is_after(Date::Utility->today)) {
                $date_first_contact = Date::Utility->today->date_yyyymmdd;
            }
        }
        catch {
            $date_first_contact = Date::Utility->today->date_yyyymmdd;
        };
    } else {
        $date_first_contact = Date::Utility->today->date_yyyymmdd;
    }

    my ($user, $client, $error, $error_msg);
    my $source            = $details->{source};
    my $utm_source        = $details->{utm_source};
    my $utm_medium        = $details->{utm_medium};
    my $utm_campaign      = $details->{utm_campaign};
    my $gclid_url         = $details->{gclid_url};
    my $has_social_signup = $details->{has_social_signup} // 0;
    my $signup_device     = $details->{signup_device};

    try {
        # Any countries covered by GDPR should default to not sending email, but we would like to
        # include other users in our default marketing emails.
        my $country_company = $brand_country_instance->real_company_for_country($residence);
        my $email_consent = $country_company ? LandingCompany::Registry::get($country_company)->email_consent->{default} : 0;

        $user = BOM::User->create(
            email             => $email,
            password          => $password,
            email_verified    => 1,
            has_social_signup => $has_social_signup,
            email_consent     => $email_consent,
            $source             ? (app_id             => $source)             : (),
            $utm_source         ? (utm_source         => $utm_source)         : (),
            $utm_medium         ? (utm_medium         => $utm_medium)         : (),
            $utm_campaign       ? (utm_campaign       => $utm_campaign)       : (),
            $gclid_url          ? (gclid_url          => $gclid_url)          : (),
            $date_first_contact ? (date_first_contact => $date_first_contact) : (),
            $signup_device      ? (signup_device      => $signup_device)      : ());
        my $landing_company = $residence ? $brand_country_instance->virtual_company_for_country($residence) : $default_virtual;
        my $broker_code = LandingCompany::Registry::get($landing_company)->broker_codes->[0];
        $client = $user->create_client(
            broker_code        => $broker_code,
            client_password    => $password,
            first_name         => '',
            last_name          => '',
            myaffiliates_token => $details->{myaffiliates_token} // '',
            email              => $email,
            residence          => $residence || '',
            address_line_1     => '',
            address_line_2     => '',
            address_city       => '',
            address_state      => '',
            address_postcode   => '',
            phone              => '',
            secret_question    => '',
            secret_answer      => ''
        );

    }
    catch {
        $error = $_;
    };
    if ($error) {
        warn("Virtual: create_client err [$error]");
        return {error => 'invalid'};
    }
    $client->deposit_virtual_funds($source, localize('Virtual money credit to account'));

    return {
        client => $client,
        user   => $user,
    };
}

1;
