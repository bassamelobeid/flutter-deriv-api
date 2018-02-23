package BOM::Platform::Account::Virtual;

use strict;
use warnings;

use Try::Tiny;

use Brands;
use BOM::User::Client;
use LandingCompany::Registry;

use BOM::Platform::Password;
use BOM::Platform::Runtime;
use BOM::User;
use BOM::Platform::Token;
use BOM::Platform::Context qw(localize request);

sub create_account {
    my $args    = shift;
    my $details = $args->{details};

    my $email     = lc $details->{email};
    my $password  = $details->{client_password} ? BOM::Platform::Password::hashpw($details->{client_password}) : '';
    my $residence = $details->{residence};

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->new_accounts) {
        return {error => 'invalid'};
    } elsif (BOM::User->new({email => $email})) {
        return {error => 'duplicate email'};
    } elsif ($residence && Brands->new(name => request()->brand)->countries_instance->restricted_country($residence)) {
        return {error => 'invalid residence'};
    }

    my ($client, $error);
    my $brand_name = $details->{brand_name} // request()->brand;
    try {
        # set virtual company if residence is provided otherwise use brand name to infer the broker code
        my $default_virtual;
        $default_virtual = 'champion-virtual' if $brand_name eq 'champion';
        $default_virtual = 'virtual'          if $brand_name eq 'binary';
        return {error => 'invalid brand company'} unless $default_virtual;

        my $company_name =
            $residence ? Brands->new(name => $brand_name)->countries_instance->virtual_company_for_country($residence) : $default_virtual;

        $client = BOM::User::Client->register_and_return_new_client({
            broker_code                   => LandingCompany::Registry::get($company_name)->broker_codes->[0],
            client_password               => $password,
            salutation                    => '',
            last_name                     => '',
            first_name                    => '',
            myaffiliates_token            => $details->{myaffiliates_token} // '',
            date_of_birth                 => undef,
            citizen                       => '',
            residence                     => $residence || '',
            email                         => $email,
            address_line_1                => '',
            address_line_2                => '',
            address_city                  => '',
            address_state                 => '',
            address_postcode              => '',
            phone                         => '',
            secret_question               => '',
            secret_answer                 => '',
            myaffiliates_token_registered => 0,
            checked_affiliate_exposures   => 0,
            latest_environment            => $details->{latest_environment} // '',
        });
    }
    catch {
        $error = $_;
    };
    if ($error) {
        warn("Virtual: register_and_return_new_client err [$error]");
        return {error => 'invalid'};
    }

    my $source            = $details->{source};
    my $utm_source        = $details->{utm_source};
    my $utm_medium        = $details->{utm_medium};
    my $utm_campaign      = $details->{utm_campaign};
    my $gclid_url         = $details->{gclid_url};
    my $email_consent     = $details->{email_consent};
    my $has_social_signup = $details->{has_social_signup} // 0;

    my $user = BOM::User->create(
        email             => $email,
        password          => $password,
        email_verified    => 1,
        has_social_signup => $has_social_signup,
        $email_consent ? (email_consent => $email_consent) : (),
        $source        ? (app_id        => $source)        : (),
        $utm_source    ? (utm_source    => $utm_source)    : (),
        $utm_medium    ? (utm_medium    => $utm_medium)    : (),
        $utm_campaign  ? (utm_campaign  => $utm_campaign)  : (),
        $gclid_url     ? (gclid_url     => $gclid_url)     : ());
    $user->add_loginid({loginid => $client->loginid});
    $user->save;
    $client->deposit_virtual_funds($source, localize('Virtual money credit to account'));

    return {
        client => $client,
        user   => $user,
    };
}

1;
