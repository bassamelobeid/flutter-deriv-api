package BOM::WebSocketAPI::v3::NewAccount;

use strict;
use warnings;

use List::MoreUtils qw(any);
use BOM::Platform::Account::Virtual;
use BOM::Platform::Locale;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::User;
use BOM::Platform::Account;
use BOM::Platform::Context qw(localize);

sub new_account_virtual {
    my ($c, $args) = @_;

    my %details = %{$args};
    my $code    = delete $details{verification_code};

    my $err_code;
    if (BOM::Platform::Account::validate_verification_code($details{email}, $code)) {
        my $acc = BOM::Platform::Account::Virtual::create_account({details => \%details});
        if (not $acc->{error}) {
            my $client  = $acc->{client};
            my $account = $client->default_account->load;

            return {
                msg_type => 'new_account_virtual',
                account  => {
                    client_id => $client->loginid,
                    currency  => $account->currency_code,
                    balance   => $account->balance,
                }};
        }
        $err_code = $acc->{error};
    } else {
        $c->app->log->info("invalid email verification code: $details{email}, $code");
        $err_code = 'email unverified';
    }

    return $c->new_error('new_account_virtual', $err_code, BOM::Platform::Locale::error_map()->{$err_code});
}

sub verify_email {
    my ($c, $args) = @_;
    my $email = $args->{verify_email};

    if (BOM::Platform::User->new({email => $email})) {
        $c->app->log->warn("verify_email, [$email] already a Binary.com user, no email sent");
    } else {
        my $code = BOM::Platform::Account::get_verification_code($email);

        my $website = $c->stash('request')->website;
        send_email({
            from               => $website->config->get('customer_support.email'),
            to                 => $email,
            subject            => localize('Verify your email address - [_1]', $website->display_name),
            message            => [localize('Your email address verification code is: ' . $code)],
            use_email_template => 1,
        });
    }

    return {
        msg_type     => 'verify_email',
        verify_email => 1                 # always return 1, so not to leak client's email
    };
}

1;
