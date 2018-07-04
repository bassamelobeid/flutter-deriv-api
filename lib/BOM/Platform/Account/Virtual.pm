package BOM::Platform::Account::Virtual;

use strict;
use warnings;

use Try::Tiny;

use Brands;
use LandingCompany::Registry;

use BOM::User;
use BOM::User::Password;
use BOM::Config::Runtime;
use BOM::Platform::Context qw(localize request);

sub create_account {
    my $args    = shift;
    my $details = $args->{details};

    my $email     = lc $details->{email};
    my $password  = $details->{client_password} ? BOM::User::Password::hashpw($details->{client_password}) : '';
    my $residence = $details->{residence};

    if (BOM::Config::Runtime->instance->app_config->system->suspend->new_accounts) {
        return {error => 'invalid'};
    } elsif (BOM::User->new({email => $email})) {
        return {error => 'duplicate email'};
    } elsif ($residence && Brands->new(name => request()->brand)->countries_instance->restricted_country($residence)) {
        return {error => 'invalid residence'};
    }

    my ($user, $client, $error);
    my $source            = $details->{source};
    my $utm_source        = $details->{utm_source};
    my $utm_medium        = $details->{utm_medium};
    my $utm_campaign      = $details->{utm_campaign};
    my $gclid_url         = $details->{gclid_url};
    my $has_social_signup = $details->{has_social_signup} // 0;

    try {
        # Any countries covered by GDPR should default to not sending email, but we would like to
        # include other users in our default marketing emails.
        my $brand_name = $details->{brand_name} // request()->brand;
        my $brand_country_instance = Brands->new(name => $brand_name)->countries_instance;
        my $country_company        = $brand_country_instance->real_company_for_country($residence);
        my $email_consent          = $country_company ? LandingCompany::Registry::get($country_company)->email_consent->{default} : 0;

        # set virtual company if residence is provided otherwise use brand name to infer the broker code
        my $default_virtual;
        $default_virtual = 'champion-virtual' if $brand_name eq 'champion';
        $default_virtual = 'virtual'          if $brand_name eq 'binary';
        return {error => 'invalid brand company'} unless $default_virtual;

        $user = BOM::User->create(
            email             => $email,
            password          => $password,
            email_verified    => 1,
            has_social_signup => $has_social_signup,
            email_consent     => $email_consent,
            $source       ? (app_id       => $source)       : (),
            $utm_source   ? (utm_source   => $utm_source)   : (),
            $utm_medium   ? (utm_medium   => $utm_medium)   : (),
            $utm_campaign ? (utm_campaign => $utm_campaign) : (),
            $gclid_url    ? (gclid_url    => $gclid_url)    : ());

        my $landing_company = $residence ? $brand_country_instance->virtual_company_for_country($residence) : $default_virtual;
        my $broker_code = LandingCompany::Registry::get($landing_company)->broker_codes->[0];

        $client = $user->create_client(
            broker_code      => $broker_code,
            client_password  => $password,
            first_name       => '',
            last_name        => '',
            email            => $email,
            residence        => $residence || '',
            address_line_1   => '',
            address_line_2   => '',
            address_city     => '',
            address_state    => '',
            address_postcode => '',
            phone            => '',
            secret_question  => '',
            secret_answer    => ''
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
