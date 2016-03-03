package BOM::Platform::Account::Real::default;

use strict;
use warnings;

use Try::Tiny;
use Locale::Country;
use List::MoreUtils qw(any);
use DataDog::DogStatsd::Helper qw(stats_inc);
use Data::Validate::Sanctions qw(is_sanctioned);

use BOM::Utility::Desk;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::System::Config;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Account;

sub _validate {
    my $args = shift;
    my ($from_client, $user) = @{$args}{'from_client', 'user'};
    my $country = $args->{country} || '';

    my $details;
    my ($broker, $residence) = ('', '');
    if ($details = $args->{details}) {
        ($broker, $residence) = @{$details}{'broker_code', 'residence'};
    }

    my $logger = get_logger();
    my $msg    = "acc opening err: from_loginid[" . $from_client->loginid . "], broker[$broker], country[$country], residence[$residence], error: ";

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->new_accounts) {
        $logger->warn($msg . 'new account opening suspended');
        return {error => 'invalid'};
    }
    if ($country and BOM::Platform::Client::check_country_restricted($country)) {
        $logger->warn($msg . "restricted IP country [$country]");
        return {error => 'invalid'};
    }
    unless ($user->email_verified) {
        return {error => 'email unverified'};
    }
    unless ($from_client->residence) {
        return {error => 'no residence'};
    }

    if ($details) {
        if (BOM::Platform::Client::check_country_restricted($residence) or $from_client->residence ne $residence) {
            $logger->warn($msg . "restricted residence [$residence], or mismatch with from_client residence: " . $from_client->residence);
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
        if (any { $_ =~ qr/^($broker)\d+$/ } ($user->loginid)) {
            return {error => 'duplicate email'};
        }
        if (BOM::Database::DataMapper::Client->new({broker_code => $broker})->get_duplicate_client($details)) {
            return {error => 'duplicate name DOB'};
        }

        # mininum age check: Estonia = 21, others = 18
        my $dob_date     = Date::Utility->new($details->{date_of_birth});
        my $minimumAge   = ($residence eq 'ee') ? 21 : 18;
        my $now          = Date::Utility->new;
        my $mmyy         = $now->months_ahead(-12 * $minimumAge);
        my $day_of_month = $now->day_of_month;
        # we should pay special attention to 02-29 because maybe there is no such date $minimumAge years ago
        if ($day_of_month == 29 && $now->month == 2) {
            $day_of_month = $day_of_month - 1;
        }
        my $cutoff = Date::Utility->new($day_of_month . '-' . $mmyy);
        if ($dob_date->is_after($cutoff)) {
            return {error => 'too young'};
        }

        # TODO: to be removed later
        BOM::Platform::Account::invalid_japan_access_check($residence, $from_client->email);
    }
    return;
}

sub create_account {
    my $args = shift;
    my ($from_client, $user, $details) = @{$args}{'from_client', 'user', 'details'};

    if (my $error = _validate($args)) {
        return $error;
    }
    my $register = _register_client($details);
    return $register if ($register->{error});

    return _after_register_client({
        client  => $register->{client},
        user    => $user,
        details => $details,
    });
}

sub _register_client {
    my $details = shift;

    my ($client, $error);
    try { $client = BOM::Platform::Client->register_and_return_new_client($details); }
    catch {
        $error = $_;
    };
    if ($error) {
        get_logger()->warn("Real: register_and_return_new_client err [$error]");
        return {error => 'invalid'};
    }
    return {client => $client};
}

sub _after_register_client {
    my $args = shift;
    my ($client, $user, $details) = @{$args}{'client', 'user', 'details'};

    if (not $client->is_virtual) {
        $client->set_status('tnc_approval', 'system', BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version);
        $client->save;
    }
    $user->add_loginid({loginid => $client->loginid});
    $user->save;

    my $client_loginid = $client->loginid;
    my $client_name = join(' ', $client->salutation, $client->first_name, $client->last_name);
    if (is_sanctioned($client->first_name, $client->last_name)) {
        $client->add_note('UNTERR', "UN Sanctions: $client_loginid suspected ($client_name)\n" . "Check possible match in UN sanctions list.");
    }

    my $emailmsg = "$client_loginid - Name and Address\n\n\n\t\t $client_name \n\t\t";
    my @address = map { $client->$_ } qw(address_1 address_2 city state postcode);
    $emailmsg .= join("\n\t\t", @address, Locale::Country::code2country($client->residence));
    $client->add_note("New Sign-Up Client [$client_loginid] - Name And Address Details", "$emailmsg\n");

    if (BOM::Platform::Runtime->instance->app_config->system->on_production) {
        try {
            my $desk_api = BOM::Utility::Desk->new({
                desk_url     => BOM::System::Config::third_party->{desk}->{api_uri},
                api_key      => BOM::System::Config::third_party->{desk}->{api_key},
                secret_key   => BOM::System::Config::third_party->{desk}->{api_key_secret},
                token        => BOM::System::Config::third_party->{desk}->{access_token},
                token_secret => BOM::System::Config::third_party->{desk}->{access_token_secret},
            });

            $details->{loginid}  = $client_loginid;
            $details->{language} = request()->language;
            $desk_api->upload($details);
            get_logger()->info("Created desk.com account for loginid $client_loginid");
        }
        catch {
            get_logger->warn("Unable to add loginid $client_loginid (" . $client->email . ") to desk.com API: $_");
        };
    }
    stats_inc("business.new_account.real");
    stats_inc("business.new_account.real." . $client->broker);

    return {
        client => $client,
        user   => $user,
    };
}

1;
