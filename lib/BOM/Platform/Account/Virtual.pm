package BOM::Platform::Account::Virtual;

use strict;
use warnings;

use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::System::Password;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::SessionCookie;

sub create_account {
    my $args = shift;
    my ($email, $password, $residence, $source, $env, $aff_token) = @{$args}{'email', 'password', 'residence', 'source', 'env', 'aff_token'};
    $password = BOM::System::Password::hashpw($password);
    $email    = lc $email;

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->new_accounts) {
        return {err => 'Sorry, new account opening is suspended for the time being.'};
    }
    if (BOM::Platform::User->new({email => $email})) {
        return {
            err_type => 'duplicate account',
            err      => 'Your provided email address is already in use by another Login ID'
        };
    }
    if (BOM::Platform::Client::check_country_restricted($residence)) {
        return {err => 'Sorry, our service is not available for your country of residence'};
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
        '/user/validate_link',
        {
            verify_token => BOM::Platform::SessionCookie->new({
                    email      => $email,
                    expires_in => 3600
                }
                )->token,
            step => 'account'
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

1;
