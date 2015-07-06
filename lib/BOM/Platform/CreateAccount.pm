package BOM::Platform::CreateAccount;

use strict;
use warnings;

use Try::Tiny;
use Locale::Country;
use List::MoreUtils qw(any);
use Mojo::Util qw(url_escape);
use DataDog::DogStatsd::Helper qw(stats_inc);
use Data::Validate::Sanctions qw(is_sanctioned);
use JSON qw(encode_json);

use BOM::Utility::Desk;
use BOM::System::Password;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::MyAffiliates::TrackingHandler;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::EmailToken;

sub create_vr_acc {
    my $args = shift;
    my ($email, $password, $source, $env, $aff_token) = @{$args}{'email', 'password', 'source', 'env', 'aff_token'};
    $password = BOM::System::Password::hashpw($password);

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->new_accounts) {
        return {
            err_type => 'new_acc_suspend',
            err      => localize('Sorry, new account opening is suspended for the time being.'),
        };
    }
    if (BOM::Platform::User->new({email => $email})) {
        return {
            err_type => 'duplicate_acc',
            err      => 1,
        };
    }

    my ($client, $register_err);
    try {
        $client = BOM::Platform::Client->register_and_return_new_client({
            broker_code                   => request()->virtual_account_broker->code,
            client_password               => $password,
            salutation                    => '',
            last_name                     => '',
            first_name                    => '',
            myaffiliates_token            => $aff_token,
            date_of_birth                 => undef,
            citizen                       => '',
            residence                     => '',
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
            source                        => $source,
            latest_environment            => $env
        });
    }
    catch {
        $register_err = $_;
    };
    return {
        err_type => 'register',
        err      => $register_err
    } if ($register_err);

    my $user = BOM::Platform::User->create(
        email    => $email,
        password => $password
    );
    $user->add_loginid({loginid => $client->loginid});
    $user->add_login_history({
        environment => $env,
        successful  => 't',
        action      => 'login'
    });
    $user->save;
    $client->deposit_virtual_funds;

    my $link = request()->url_for(
        '/user/verify_email',
        {
            email        => url_escape($email),
            verify_token => BOM::Platform::EmailToken->new(email => $email)->token,
        });
    my $email_content;
    BOM::Platform::Context::template->process('email/resend_verification.html.tt', {link => $link}, \$email_content)
        || die BOM::Platform::Context::template->error();

    send_email({
        from               => request()->website->config->get('customer_support.email'),
        to                 => $email,
        subject            => localize('Verify your email address - [_1]', request()->website->display_name),
        message            => [$email_content],
        use_email_template => 1,
    });
    stats_inc("business.new_account.virtual");

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

sub real_acc_checks {
    my $args = shift;
    my ($email, $from_loginid, $broker, $country) = @{$args}{'email', 'from_loginid', 'broker', 'country'};

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->new_accounts) {
        return {
            err_type => 'new_acc_suspend',
            err      => localize('Sorry, new account opening is suspended for the time being.'),
        };
    }
    if (my $error = BOM::Platform::Client::check_jurisdiction($country)) {
        return {
            err_type => 'restricted_country',
            err      => $error,
        };
    }

    my ($user, $from_client);
    if (   not $user = BOM::Platform::User->new({email => $email})
        or not $from_client = BOM::Platform::Client->new({loginid => $from_loginid}))
    {
        return {
            err_type => 'invalid_user',
            err      => localize("Sorry, an error occurred. Please contact customer support if this problem persists."),
        };
    }
    if ($broker and any { $_ =~ qr/^($broker)\d+$/ } ($user->loginid)) {
        return {
            err_type => 'duplicate_acc',
            err      => '1'
        };
    }
    return {
        user        => $user,
        from_client => $from_client,
    };
}

sub financial_acc_checks {
    my $args = shift;
    if (BOM::Platform::Runtime->instance->broker_codes->landing_company_for($args->{from_loginid})->short ne 'malta') {
        return {
            error_type => 'no_financial',
            err        => localize('Financial account opening unavailable'),
        };
    }
    return real_acc_checks($args);
}

sub register_real_acc {
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

    my $warning;
    if (BOM::Platform::Runtime->instance->app_config->system->on_production) {
        try {
            my $desk_api = BOM::Utility::Desk->new({
                username => BOM::Platform::Runtime->instance->app_config->system->desk_com->account_username,
                password => BOM::Platform::Runtime->instance->app_config->system->desk_com->account_password,
                desk_url => BOM::Platform::Runtime->instance->app_config->system->desk_com->desk_url . 'customers',
            });

            $details->{loginid}  = $client_loginid;
            $details->{language} = request()->language;
            $desk_api->upload($details);
        }
        catch {
            $warning = "Unable to add loginid $client_loginid (" . $client->email . ") to desk.com API: $_";
        };
    }
    stats_inc("business.new_account.real");
    stats_inc("business.new_account.real." . $client->broker);

    my $login = $client->login();
    return {
        err_type => 'login',
        err      => $login->{error},
    } if ($login->{error});

    my $real_acc = {
        client => $client,
        user   => $user,
        token  => $login->{token},
    };
    $real_acc->{warning} = $warning if ($warning);
    return $real_acc;
}

sub register_financial_acc {
    my $args = shift;
    my $acc  = register_real_acc({
        user    => $args->{user},
        details => $args->{details},
    });
    return $acc if ($acc->{err});

    my $client               = $acc->{client};
    my $financial_evaluation = $args->{financial_evaluation};

    $client->financial_assessment({
        data            => encode_json($financial_evaluation->{user_data}),
        is_professional => $financial_evaluation->{total_score} < 60 ? 0 : 1,
    });
    $client->set_status('unwelcome', 'SYSTEM', 'Trading disabled for investment Europe ltd');
    $client->save;

    if ($financial_evaluation->{total_score} > 59) {
        send_email({
            from    => request()->website->config->get('customer_support.email'),
            to      => BOM::Platform::Runtime->instance->app_config->compliance->email,
            subject => $client->loginid . ' considered as professional trader',
            message =>
                ["$client->loginid scored " . $financial_evaluation->{total_score} . " and is therefore considered a professional trader."],
        });
    }
    return $acc;
}

1;
