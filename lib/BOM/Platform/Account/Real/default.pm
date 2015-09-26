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

sub validate {
    my $args = shift;
    my ($from_loginid, $broker, $country, $residence) = @{$args}{'from_loginid', 'broker', 'country', 'residence'};

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->new_accounts) {
        return {err => 'Sorry, new account opening is suspended for the time being.'};
    }
    if (BOM::Platform::Client::check_country_restricted($country)) {
        return {err => 'Sorry, our service is not available for your country of residence'};
    }

    my ($user, $from_client);
    unless ($from_client = BOM::Platform::Client->new({loginid => $from_loginid})
        and $user = BOM::Platform::User->new({email => $from_client->email}))
    {
        return {err => 'Sorry, an error occurred. Please contact customer support if this problem persists.'};
    }

    if ($broker and any { $_ =~ qr/^($broker)\d+$/ } ($user->loginid)) {
        return {
            err_type => 'duplicate account',
            err      => 'Your provided email address is already in use by another Login ID'
        };
    }
    unless ($user->email_verified) {
        return {
            err_type => 'email unverified',
            err      => 'Your email address is unverified'
        };
    }
    unless ($from_client->residence) {
        return {
            err_type => 'no residence',
            err      => 'Your account has no country of residence'
        };
    }
    if ($residence and $from_client->residence ne $residence) {
        return {err => 'Your country of residence is invalid'};
    }

    return {
        user        => $user,
        from_client => $from_client,
    };
}

sub create_account {
    my $args = shift;
    my ($user, $details) = @{$args}{'user', 'details'};

    my ($client, $register_err);
    try { $client = BOM::Platform::Client->register_and_return_new_client($details); }
    catch {
        $register_err = $_;
    };
    return {
        err_type => 'register',
        err      => $register_err
    } if ($register_err);

    if (any { $client->landing_company->short eq $_ } qw(malta maltainvest iom)) {
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

    my $login = $client->login();
    return {
        err_type => 'login',
        err      => $login->{error},
    } if ($login->{error});

    return {
        client => $client,
        user   => $user,
        token  => $login->{token},
    };
}

1;
