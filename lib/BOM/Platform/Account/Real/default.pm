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
use BOM::Platform::Context qw(request);
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

    if ($args->{date_of_birth} and $args->{date_of_birth} =~ /^(\d{4})-(\d\d?)-(\d\d?)$/) {
        my $dob_error;
        try {
            $args->{date_of_birth} = Date::Utility->new($args->{date_of_birth})->date;
        }
        catch {
            $dob_error = {error => 'InvalidDateOfBirth'};
        };
        return $dob_error if $dob_error;
    }

    my $lc = LandingCompany::Registry->get_by_broker($broker);
    foreach my $key (get_account_fields($lc->short)) {
        my $value = $args->{$key};
        # as we are going to support multiple accounts per landing company
        # so we need to copy secret question and answer from old clients
        # if present else we will take the new one
        $value = $client->secret_question || $value if ($key eq 'secret_question');

        if ($key eq 'secret_answer') {
            if (my $answer = $client->secret_answer) {
                $value = $answer;
            } elsif ($value) {
                $value = BOM::User::Utility::encrypt_secret_answer($value);
            }
        }

        if (not $client->is_virtual) {
            $value ||= $client->$key;
        }
        # we need to store null for these fields not blank if not defined
        $details->{$key} = (grep { $key eq $_ } qw /place_of_birth tax_residence tax_identification_number/) ? $value : $value // '';

        # account fields place_of_birth tax_residence tax_identification_number
        # are optional for all except financial account
        next
            if (any { $key eq $_ }
            qw(address_line_2 address_state address_postcode salutation place_of_birth tax_residence tax_identification_number));
        return {error => 'InsufficientAccountDetails'} if (not $details->{$key});
    }

    # it's not a standard way, we need to refactor this sub later to
    # to remove reference to database columns name from code
    # need to check broker here as its upgrade from MLT so
    # landing company would be malta not maltainvest
    if ($broker eq 'MF') {
        foreach my $field (qw /place_of_birth tax_residence tax_identification_number/) {
            return {error => 'InsufficientAccountDetails'} unless $args->{$field};
            $details->{$field} = $args->{$field};
        }
    }

    # Client cannot change citizenship if already set
    $details->{citizen} = ($client->citizen || $args->{citizen}) // '';
    return {error => 'InsufficientAccountDetails'} if ($lc->citizen_required && !$details->{citizen});

    $details->{place_of_birth} = ($client->place_of_birth || $args->{place_of_birth}) // '';

    return {details => $details};
}

sub get_account_fields {
    my @account_fields = qw(salutation first_name last_name date_of_birth residence address_line_1 address_line_2
        address_city address_state address_postcode phone secret_question secret_answer place_of_birth
        tax_residence tax_identification_number account_opening_reason);
    return @account_fields;
}

sub validate_dob {
    my ($dob, $residence) = @_;
    # mininum age check: Estonia = 21, others = 18
    my $dob_date     = Date::Utility->new($dob);
    my $minimumAge   = ($residence eq 'ee') ? 21 : 18;
    my $now          = Date::Utility->new;
    my $mmyy         = $now->months_ahead(-12 * $minimumAge);
    my $day_of_month = $now->day_of_month;
    # we should pay special attention to 02-29 because maybe there is no such date $minimumAge years ago
    if ($day_of_month == 29 && $now->month == 2) {
        $day_of_month = $day_of_month - 1;
    }
    my $cutoff = Date::Utility->new($day_of_month . '-' . $mmyy);
    return {error => 'too young'} if $dob_date->is_after($cutoff);
    return undef;
}

1;
