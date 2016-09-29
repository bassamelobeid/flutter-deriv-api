package BOM::Platform::Account::Virtual;

use strict;
use warnings;

use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::System::Password;
use BOM::Platform::Runtime;
use BOM::Platform::Countries;

use BOM::Platform::Context::Request;
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Token;
use BOM::Platform::Account;

sub create_account {
    my $args    = shift;
    my $details = $args->{details};

    my $email     = lc $details->{email};
    my $password  = BOM::System::Password::hashpw($details->{client_password});
    my $residence = $details->{residence};

    # TODO: to be removed later
    BOM::Platform::Account::invalid_japan_access_check($residence, $email);

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->new_accounts) {
        return {error => 'invalid'};
    } elsif (BOM::Platform::User->new({email => $email})) {
        return {error => 'duplicate email'};
    } elsif (BOM::Platform::Client::check_country_restricted($residence)) {
        return {error => 'invalid residence'};
    }

    my ($client, $error);
    try {
        die 'residence is empty' if (not $residence);
        my $company_name = BOM::Platform::Countries->instance->virtual_company_for_country($residence);

        $client = BOM::Platform::Client->register_and_return_new_client({
            broker_code                   => BOM::Platform::LandingCompany::Registry::get($company_name)->broker_codes->[0],
            client_password               => $password,
            salutation                    => '',
            last_name                     => '',
            first_name                    => '',
            myaffiliates_token            => $details->{myaffiliates_token} // '',
            date_of_birth                 => undef,
            citizen                       => '',
            residence                     => $residence,
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

    my $source        = $details->{source};
    my $utm_source    = $details->{utm_source};
    my $utm_medium    = $details->{utm_medium};
    my $utm_campaign  = $details->{utm_campaign};
    my $email_consent = $details->{email_consent};

    my $user = BOM::Platform::User->create(
        email          => $email,
        password       => $password,
        email_verified => 1,
        $email_consent ? (email_consent => $email_consent) : (),
        $source        ? (app_id        => $source)        : (),
        $utm_source    ? (utm_source    => $utm_source)    : (),
        $utm_medium    ? (utm_medium    => $utm_medium)    : (),
        $utm_campaign  ? (utm_campaign  => $utm_campaign)  : ());
    $user->add_loginid({loginid => $client->loginid});
    $user->save;
    $client->deposit_virtual_funds($source);

    stats_inc("business.new_account.virtual");

    return {
        client => $client,
        user   => $user,
    };
}

1;
