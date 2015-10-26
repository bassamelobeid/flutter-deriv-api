package BOM::Platform::Account::Virtual;

use strict;
use warnings;

use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::Utility::Log4perl qw(get_logger);
use BOM::System::Password;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::SessionCookie;

sub create_account {
    my $args    = shift;
    my $details = $args->{details};
    my ($email, $password, $residence) = @{$details}{'email', 'client_password', 'residence'};
    $password = BOM::System::Password::hashpw($password);
    $email    = lc $email;

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->new_accounts) {
        return {error => 'invalid'};
    } elsif (BOM::Platform::User->new({email => $email})) {
        return {error => 'duplicate email'};
    } elsif (BOM::Platform::Client::check_country_restricted($residence)) {
        return {error => 'invalid'};
    }

    my ($client, $error);
    try {
        $client = BOM::Platform::Client->register_and_return_new_client({
            broker_code                   => request()->virtual_account_broker->code,
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
            source                        => $details->{source} // '',
            latest_environment            => $details->{latest_environment} // '',
        });
    }
    catch {
        $error = $_;
    };
    if ($error) {
        get_logger()->warn("Virtual: register_and_return_new_client err [$error]");
        return {error => 'invalid'};
    }

    my $user = BOM::Platform::User->create(
        email    => $email,
        password => $password
    );
    $user->add_loginid({loginid => $client->loginid});
    $user->add_login_history({
        environment => $details->{latest_environment} // '',
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

    return {
        client => $client,
        user   => $user,
    };
}

1;
