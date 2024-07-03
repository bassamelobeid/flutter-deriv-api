package BOM::Platform::Account::Virtual;

use strict;
use warnings;

use Syntax::Keyword::Try;
use List::Util qw(any first);

use BOM::User;
use BOM::User::Password;
use BOM::Config::Runtime;
use BOM::Platform::Context qw(localize request);

use Business::Config::Account::Type::Registry;
use Business::Config::LandingCompany::Registry;

sub create_account {
    my $args               = shift;
    my $details            = $args->{details};
    my $email              = lc $details->{email};
    my $password           = $details->{client_password} ? BOM::User::Password::hashpw($details->{client_password}) : '';
    my $residence          = $details->{residence};
    my $date_first_contact = $details->{date_first_contact};
    my $brand_name         = $details->{brand_name} // request()->brand->name;
    my $country            = Business::Config::Country::Registry->new()->by_code($residence // '');
    my $app_config         = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update;

    my $account_type_name = $details->{account_type} or return {error => {code => 'AccountTypeMissing'}};                # default to 'trading'
    my $account_type      = Business::Config::Account::Type::Registry->new()->account_type_by_name($account_type_name)
        or return {error => {code => 'InvalidAccountType'}};
    # TODO: move it to rule engine
    return {error => {code => 'InvalidDemoAccountType'}} unless $account_type->is_regulation_supported('virtual');

    my $category = $account_type->category->name;

    if ($app_config->system->suspend->new_accounts) {
        return {error => {code => 'invalid'}};
    }

    my $user = BOM::User->new(email => $email);
    if ($user) {
        return {error => {code => 'DuplicateVirtualWallet'}}
            if $category eq 'wallet' && $user->bom_virtual_wallet_loginid;    # a virtual wallet client already exists
        return {error => {code => 'duplicate email'}}
            if $category eq 'trading' && $user->bom_virtual_loginid;          # a virtual trading client already exists
    }

    # we should check for restricted_country
    # we will also check for `is_signup_allowed` && `is_partner_signup_allowed`
    return {error => {code => 'invalid residence'}} unless $country;

    if ($country->restricted()) {
        return {error => {code => 'invalid residence'}};
    }

    my $signup_config = $country->signup();

    if (!$signup_config->{account} && !$signup_config->{partners}) {
        return {error => {code => 'invalid residence'}};
    }

    # set virtual company if residence is provided otherwise use brand name to infer the broker code
    my $virtual_company_for_brand = _virtual_company_for_brand($brand_name);
    return {error => {code => 'InvalidBrand'}} unless $virtual_company_for_brand;

    #return error if date_first_contact is in future or invalid
    # date_first_contact is used by marketing to record when users first touched a binary.com site.
    # it must be passed in in GMT time to match the server timezone.
    if (defined $date_first_contact) {
        try {
            my $contact_date = Date::Utility->new($date_first_contact);
            #Any dates older than 30 days set to 30 days old
            if ($contact_date->is_before(Date::Utility->today->minus_time_interval('30d'))) {
                $date_first_contact = Date::Utility->today->minus_time_interval('30d')->date_yyyymmdd;
            } elsif ($contact_date->is_after(Date::Utility->today)) {
                $date_first_contact = Date::Utility->today->date_yyyymmdd;
            }
        } catch {
            $date_first_contact = Date::Utility->today->date_yyyymmdd;
        }
    } else {
        $date_first_contact = Date::Utility->today->date_yyyymmdd;
    }

    my $client;
    my $source            = $details->{source};
    my $utm_source        = $details->{utm_source};
    my $utm_medium        = $details->{utm_medium};
    my $utm_campaign      = $details->{utm_campaign};
    my $gclid_url         = $details->{gclid_url};
    my $has_social_signup = $details->{has_social_signup} // 0;
    my $signup_device     = $details->{signup_device};
    my $email_consent     = $details->{email_consent};

    # If not defined take it from the LC
    if (not defined $email_consent) {
        my $country_company = $country->derived_company() // $country->financial_company();
        my $landing_company;

        $landing_company = Business::Config::LandingCompany::Registry->new()->by_code($country_company) if $country_company;

        $email_consent = $landing_company ? $landing_company->marketing_email_consent->{default} : 0;
    }

    try {
        $user = BOM::User->create(
            email             => $email,
            password          => $password,
            email_verified    => $details->{email_verified} // 1,
            has_social_signup => $has_social_signup,
            email_consent     => $email_consent,
            $source             ? (app_id             => $source)             : (),
            $utm_source         ? (utm_source         => $utm_source)         : (),
            $utm_medium         ? (utm_medium         => $utm_medium)         : (),
            $utm_campaign       ? (utm_campaign       => $utm_campaign)       : (),
            $gclid_url          ? (gclid_url          => $gclid_url)          : (),
            $date_first_contact ? (date_first_contact => $date_first_contact) : (),
            $signup_device      ? (signup_device      => $signup_device)      : (),
            $args->{utm_data}   ? (utm_data           => $args->{utm_data})   : (),
        ) unless ($user);

        my $landing_company = $country->virtual_company() // $virtual_company_for_brand;
        my $broker_code     = $account_type->get_single_broker_code($landing_company);

        if (($utm_campaign // '') eq $app_config->partners->campaign->dynamicworks) {

            my $result = $user->set_affiliated_client_details({
                partner_token => $details->{myaffiliates_token},
                provider      => $app_config->partners->campaign->dynamicworks,
            });
            delete $details->{myaffiliates_token};
            return {error => {code => 'invalid'}} unless $result;
        }

        my %args = (
            account_type       => $account_type->name,
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
            secret_answer      => '',
        );
        $client = $category eq 'wallet' ? $user->create_wallet(%args) : $user->create_client(%args);

    } catch ($e) {
        warn("Virtual: create_client err [$e]");
        return {error => {code => 'invalid'}};
    }
    $client->deposit_virtual_funds($source, localize('Virtual money credit to account'));

    return {
        client => $client,
        user   => $user,
    };
}

=head2 _virtual_company_for_brand

Finds the virtual landing company that is allowed for a specific brand.

=over 4

=item * C<brand_name> - Name of the brand to find the virtual landing company for

=back

Returns the virtual landing company object that is allowed for the given brand, if not found: C<undef>.

=cut

sub _virtual_company_for_brand {
    my ($brand_name) = @_;

    my $list = Business::Config::LandingCompany::Registry->new()->list;

    my @lc = grep {
        $_->is_virtual && any { /^$brand_name$/ }
            $_->allowed_for_brands->@*
    } values $list->%*;

    return first { !$_->skip_virtual_creation } @lc;
}

1;
