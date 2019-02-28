package BOM::Platform::Account::Real::default;

use strict;
use warnings;
use feature 'state';
use Date::Utility;
use Try::Tiny;
use Locale::Country;
use List::MoreUtils qw(any);

use Brands;
use BOM::User::Client;
use BOM::User::Client::Desk;

use BOM::Database::ClientDB;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Client::Sanctions;

sub validate {
    my $args = shift;
    my ($from_client, $user) = @{$args}{'from_client', 'user'};

    my $details;
    my ($broker, $residence) = ('', '');
    if ($details = $args->{details}) {
        ($broker, $residence) = @{$details}{'broker_code', 'residence'};
    }

    my $msg = "acc opening err: from_loginid[" . $from_client->loginid . "], broker[$broker], residence[$residence], error: ";

    if (BOM::Config::Runtime->instance->app_config->system->suspend->new_accounts) {
        warn $msg . ' - new account opening suspended';
        return {error => 'invalid'};
    }
    unless ($user->{email_verified}) {
        return {error => 'email unverified'};
    }
    unless ($from_client->residence) {
        return {error => 'no residence'};
    }

    if ($details) {
        my $countries_instance = Brands->new(name => request()->brand)->countries_instance;

        if ($details->{citizen}
            && !defined $countries_instance->countries->country_from_code($details->{citizen}))
        {
            return {error => 'InvalidCitizenship'};
        }
        if (   $countries_instance->restricted_country($residence)
            or $from_client->residence ne $residence
            or not defined $countries_instance->countries->country_from_code($residence))
        {
            return {error => 'invalid residence'};
        }
        if ($residence eq 'gb' and not $details->{address_postcode}) {
            return {error => 'invalid UK postcode'};
        }
        if (   ($details->{address_line_1} || '') =~ /p[\.\s]+o[\.\s]+box/i
            or ($details->{address_line_2} || '') =~ /p[\.\s]+o[\.\s]+box/i)
        {
            return {error => 'invalid PO Box'};
        }
        # we don't need to check for duplicate client on adding multiple currencies
        # in that case, $from_client and $details will handle same data.
        # when it's first registration - $from_client->first_name will be empty, as VRTC does not have it.
        if ($details->{first_name} ne $from_client->first_name
            && BOM::Database::ClientDB->new({broker_code => $broker})->get_duplicate_client($details))
        {
            return {error => 'duplicate name DOB'};
        }

        my $dob_error = validate_dob($details->{date_of_birth}, $residence);
        return $dob_error if $dob_error;
    }
    return undef;
}

sub create_account {
    my $args = shift;
    my ($user, $details) = @{$args}{'user', 'details'};

    my $error = validate($args);
    return $error if $error;

    my $client = eval { $user->create_client(%$details) };

    unless ($client) {
        warn "Real: create_client exception [$@]";
        return {error => 'invalid'};
    }

    my $response = after_register_client({
        client  => $client,
        user    => $user,
        details => $details,
        ip      => $args->{ip},
        country => $args->{country},
    });

    add_details_to_desk($client, $details);

    return $response;
}

sub after_register_client {
    my $args = shift;
    my ($client, $user, $details, $ip, $country) = @{$args}{qw(client user details ip country)};

    unless ($client->is_virtual) {
        $client->status->set('tnc_approval', 'system', BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version);
    }

    BOM::Platform::Client::Sanctions->new({
            client => $client,
            brand  => Brands->new(name => request()->brand)})->check();

    my $client_loginid = $client->loginid;
    my $client_name = join(' ', $client->salutation, $client->first_name, $client->last_name);

    $client->send_new_client_email($ip, $country) if ($client->landing_company->new_client_email_event eq 'signup');

    if ($client->landing_company->short eq 'iom'
        and (length $client->first_name < 3 or length $client->last_name < 3))
    {
        my $notemsg = "$client_loginid - first name or last name less than 3 characters \n\n\n\t\t";
        $notemsg .= join("\n\t\t",
            'first name: ' . $client->first_name,
            'last name: ' . $client->last_name,
            'residence: ' . Locale::Country::code2country($client->residence));
        $client->add_note("MX Client [$client_loginid] - first name or last name less than 3 characters", "$notemsg\n");
    }

    BOM::User::Utility::set_gamstop_self_exclusion($client);

    return {
        client => $client,
        user   => $user
    };
}

sub add_details_to_desk {
    my ($client, $details) = @_;

    if (BOM::Config::on_production()) {
        try {
            my $desk_api = BOM::User::Client::Desk->new({
                desk_url     => BOM::Config::third_party()->{desk}->{api_uri},
                api_key      => BOM::Config::third_party()->{desk}->{api_key},
                secret_key   => BOM::Config::third_party()->{desk}->{api_key_secret},
                token        => BOM::Config::third_party()->{desk}->{access_token},
                token_secret => BOM::Config::third_party()->{desk}->{access_token_secret},
            });

            # we don't want to modify original details hence create
            # copy for desk.com
            my $copy = {%$details};
            $copy->{loginid}  = $client->loginid;
            $copy->{language} = request()->language;
            $desk_api->upload($copy);
        }
        catch {
            warn "Unable to add loginid " . $client->loginid . "(" . $client->email . ") to desk.com API: $_";
        };
    }

    return;
}

sub validate_account_details {
    my ($args, $client, $broker, $source) = @_;

    # If it's a virtual client, replace client with the newest real account if any
    if ($client->is_virtual) {
        $client = (sort { $b->date_joined cmp $a->date_joined } grep { not $_->is_virtual } $client->user->clients(include_disabled => 0))[0]
            // $client;
    }

    my $details = {
        broker_code                   => $broker,
        email                         => $client->email,
        client_password               => $client->password,
        myaffiliates_token_registered => 0,
        checked_affiliate_exposures   => 0,
        latest_environment            => '',
        source                        => $source,
    };

    my $affiliate_token;
    $affiliate_token = delete $args->{affiliate_token} if (exists $args->{affiliate_token});
    $details->{myaffiliates_token} = $affiliate_token || $client->myaffiliates_token || '';

    if ($args->{date_of_birth}) {
        $args->{date_of_birth} = format_date($args->{date_of_birth});
        return {error => 'InvalidDateOfBirth'} unless $args->{date_of_birth};
        my $error = validate_dob($args->{date_of_birth}, $client->residence);
        return $error if $error;
    }

    if ($args->{secret_answer} xor $args->{secret_question}) {
        return {
            error             => 'PermissionDenied',
            message_to_client => localize("Need both secret_question and secret_answer")};
    }

    return {error => 'InvalidPlaceOfBirth'}
        if ($args->{place_of_birth} and not Locale::Country::code2country($args->{place_of_birth}));

    my $lc = LandingCompany::Registry->get_by_broker($broker);

    unless ($client->is_virtual) {
        for my $field (fields_to_duplicate()) {
            if ($field eq "secret_answer") {
                $args->{$field} ||= BOM::User::Utility::decrypt_secret_answer($client->$field);
            } else {
                $args->{$field} ||= $client->$field;
            }
        }
    }

    if (my @missing = grep { !$args->{$_} } required_fields($lc)) {
        return {
            error   => 'InsufficientAccountDetails',
            details => {missing => [@missing]}};
    }

    unless ($client->is_virtual) {
        my @changed;

        for my $field (fields_cannot_change()) {
            if ($args->{$field} && $client->$field) {
                my $client_field;
                if ($field eq "secret_answer") {
                    $client_field = BOM::User::Utility::decrypt_secret_answer($client->$field);
                } else {
                    $client_field = $client->$field;
                }

                push(@changed, $field) if $client_field && ($client_field ne $args->{$field});
            }
        }
        if (@changed) {
            return {
                error   => 'CannotChangeAccountDetails',
                details => {changed => [@changed]}};
        }
    }

    $args->{secret_answer} = BOM::User::Utility::encrypt_secret_answer($args->{secret_answer}) if $args->{secret_answer};

    # This exist to accommodate some rules in our database (mostly NOT NULL and NULL constraints). Should change to be more consistent. Also used to filter the args to return for new account creation.
    my %default_values = (
        citizen                   => '',
        salutation                => '',
        first_name                => '',
        last_name                 => '',
        date_of_birth             => '',
        residence                 => '',
        address_line_1            => '',
        address_line_2            => '',
        address_city              => '',
        address_state             => '',
        address_postcode          => '',
        phone                     => '',
        secret_question           => '',
        secret_answer             => '',
        place_of_birth            => '',
        tax_residence             => '',
        tax_identification_number => '',
        account_opening_reason    => '',
        place_of_birth            => undef,
        tax_residence             => undef,
        tax_identification_number => undef
    );

    for my $field (keys %default_values) {
        $details->{$field} = $args->{$field} // $default_values{$field};
    }

    return {details => $details};
}

=head2 required_fields

Returns an array of required fields given a landing company

=cut

sub required_fields {
    my $lc = shift;

    return $lc->requirements->{signup}->@*;
}

=head2 fields_to_duplicate

Returns an array of the fields that should be duplicated between clients

=cut

sub fields_to_duplicate {
    return
        qw(citizen salutation first_name last_name date_of_birth residence address_line_1 address_line_2 address_city address_state address_postcode phone secret_question secret_answer place_of_birth tax_residence tax_identification_number account_opening_reason);
}

=head2 fields_cannot_change

Returns an array of the fields that can't be changed if they have been set before

Note: Currently only used for citizen but will expand it's use after refactoring (or be changed completely following the clientdb -> userdb changes)

=cut

sub fields_cannot_change {
    return qw(citizen place_of_birth);
}

=head2 validate_dob

check if client's date of birth is valid, meaning the client is older than residence's minimum age

=over 4

=item * C<dob> - client's date of birth in format of date_yyyymmdd means 1988-02-12

=item * C<residence> - client's residence

=back

return undef if client is older than residence's minimum age
otherwise return error hash

=cut

sub validate_dob {
    my ($dob, $residence) = @_;

    my $dob_date = try { Date::Utility->new($dob) };
    return {error => 'InvalidDateOfBirth'} unless $dob_date;

    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;
    return {error => 'invalid country'} if !defined $countries_instance;

    # Get the minimum age from the client's residence
    my $min_age = $countries_instance->minimum_age_for_country($residence);
    return {error => 'invalid residence'} unless $min_age;
    my $minimum_date = Date::Utility->new->minus_time_interval($min_age . 'y');
    return {error => 'too young'} if $dob_date->is_after($minimum_date);
    return undef;
}

sub format_date {
    my $date = shift;
    try {
        return Date::Utility->new($date)->date;
    }
    catch {
        return undef;
    };

}

1;
