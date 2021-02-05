package BOM::Platform::Account::Virtual;

use strict;
use warnings;

use Syntax::Keyword::Try;
use LandingCompany::Registry;
use List::Util qw(any first);

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
    my $virtual_company_for_brand = _virtual_company_for_brand($brand_name);
    return {error => 'InvalidBrand'} unless $virtual_company_for_brand;

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

    my ($user, $client);
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
        my $country_company = $brand_country_instance->real_company_for_country($residence);
        $email_consent = $country_company ? LandingCompany::Registry::get($country_company)->marketing_email_consent->{default} : 0;
    }

    try {
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
            $signup_device      ? (signup_device      => $signup_device)      : (),
            $args->{utm_data}   ? (utm_data           => $args->{utm_data})   : (),
        );

        my $landing_company = $residence ? $brand_country_instance->virtual_company_for_country($residence) : $virtual_company_for_brand->short;
        my $broker_code     = LandingCompany::Registry::get($landing_company)->broker_codes->[0];
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

    } catch {
        warn("Virtual: create_client err [$@]");
        return {error => 'invalid'};
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

    return first {
        $_->is_virtual && any { /^$brand_name$/ } $_->allowed_for_brands->@*
    }
    LandingCompany::Registry::all();
}

1;
