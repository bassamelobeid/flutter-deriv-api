package BOM::Platform::Account::Virtual;

use strict;
use warnings;

use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::Utility::Log4perl qw(get_logger);
use BOM::System::Password;
use BOM::Platform::Runtime;
use BOM::Platform::Context::Request;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Token::Verification;
use BOM::Platform::Account;
use BOM::Platform::Static::Config;

sub create_account {
    my $args = shift;
    my ($details, $email_verified) = @{$args}{'details', 'email_verified'};

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
        $client = BOM::Platform::Client->register_and_return_new_client({
            broker_code     => BOM::Platform::Context::Request->new(country_code => $residence)->virtual_account_broker->code,
            client_password => $password,
            salutation      => '',
            last_name       => '',
            first_name      => '',
            myaffiliates_token => $details->{myaffiliates_token} // '',
            date_of_birth      => undef,
            citizen            => '',
            residence          => $residence,
            email              => $email,
            address_line_1     => '',
            address_line_2     => '',
            address_city       => '',
            address_state      => '',
            address_postcode   => '',
            phone              => '',
            secret_question    => '',
            secret_answer      => '',
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
        password => $password,
        ($email_verified) ? (email_verified => 1) : ());
    $user->add_loginid({loginid => $client->loginid});
    $user->save;
    $client->deposit_virtual_funds;

    unless ($email_verified) {
        my $link = request()->url_for(
            '/user/validate_link',
            {
                verify_token => BOM::Platform::Token::Verification->new({
                        email       => $email,
                        expires_in  => 3600,
                        created_for => 'verify_email'
                    }
                )->token,
            });
        my $email_content;
        BOM::Platform::Context::template->process('email/resend_verification.html.tt', {link => $link}, \$email_content)
            || die BOM::Platform::Context::template->error();

        send_email({
            from               => BOM::Platform::Static::Config::get_customer_support_email(),
            to                 => $email,
            subject            => localize('Verify your email address - [_1]', request()->website->display_name),
            message            => [$email_content],
            use_email_template => 1,
        });
    }
    stats_inc("business.new_account.virtual");

    return {
        client => $client,
        user   => $user,
    };
}

1;
