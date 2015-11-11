package BOM::WebSocketAPI::v3::NewAccount;

use strict;
use warnings;

use DateTime;
use Try::Tiny;
use List::MoreUtils qw(any);
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Locale;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::User;
use BOM::Platform::Account;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Context::Request;

sub new_account_virtual {
    my ($c, $args) = @_;
    BOM::Platform::Context::request($c->stash('request'));

    my %details = %{$args};
    my $code    = delete $details{verification_code};

    my $err_code;
    if (BOM::Platform::Account::validate_verification_code($details{email}, $code)) {
        my $acc = BOM::Platform::Account::Virtual::create_account({
            details        => \%details,
            email_verified => 1
        });
        if (not $acc->{error}) {
            my $client  = $acc->{client};
            my $account = $client->default_account->load;

            return {
                msg_type            => 'new_account_virtual',
                new_account_virtual => {
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
    BOM::Platform::Context::request($c->stash('request'));

    if (BOM::Platform::User->new({email => $email})) {
        $c->app->log->warn("verify_email, [$email] already a Binary.com user, no email sent");
    } else {
        my $code = BOM::Platform::Account::get_verification_code($email);

        my $website = $c->stash('request')->website;
        send_email({
            from    => $website->config->get('customer_support.email'),
            to      => $email,
            subject => localize('Verify your email address - [_1]', $website->display_name),
            message => [localize('Your email address verification code is: ' . $code)],
        });
    }

    return {
        msg_type     => 'verify_email',
        verify_email => 1                 # always return 1, so not to leak client's email
    };
}

sub new_account_real {
    my ($c, $args) = @_;
    my $client = $c->stash('client');
    BOM::Platform::Context::request($c->stash('request'));

    my $error_map = BOM::Platform::Locale::error_map();

    unless ($client->is_virtual and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'real') {
        return $c->new_error('new_account_real', 'invalid', $error_map->{'invalid'});
    }

    # JSON::Schema "date" format only check regex. Check for valid date here
    $args->{date_of_birth} =~ /^(\d{4})-(\d\d?)-(\d\d?)$/;
    try {
        my $dob = DateTime->new(
            year  => $1,
            month => $2,
            day   => $3,
        );
        $args->{date_of_birth} = $dob->ymd;
    }
    catch { return; } or return $c->new_error('new_account_real', 'invalid DOB', $error_map->{'invalid DOB'});

    my $details = {
        broker_code     => BOM::Platform::Context::Request->new(country_code => $args->{residence})->real_account_broker->code,
        email           => $client->email,
        client_password => $client->password,
        salutation      => $args->{salutation},
        last_name       => $args->{last_name},
        first_name      => $args->{first_name},
        date_of_birth   => $args->{date_of_birth},
        residence       => $args->{residence},
        address_line_1  => $args->{address_line_1},
        address_line_2   => $args->{address_line_2}   || '',
        address_city     => $args->{address_city},
        address_state    => $args->{address_state}    || '',
        address_postcode => $args->{address_postcode} || '',
        phone            => $args->{phone},
        secret_question  => $args->{secret_question},
        secret_answer    => $args->{secret_answer},
        myaffiliates_token_registered => 0,
        checked_affiliate_exposures   => 0,
        source                        => 'websocket-api',
        latest_environment            => '',
        myaffiliates_token            => $client->myaffiliates_token || '',
    };

    my $acc = BOM::Platform::Account::Real::default::create_account({
        from_client => $client,
        user        => BOM::Platform::User->new({email => $client->email}),
        details     => $details,
    });

    if (my $err_code = $acc->{error}) {
        return $c->new_error('new_account_real', $err_code, $error_map->{$err_code});
    }

    my $new_client      = $acc->{client};
    my $landing_company = $acc->{client}->landing_company;

    return {
        msg_type            => 'new_account_real',
        new_account_real => {
            client_id                 => $new_client->loginid,
            landing_company           => $landing_company->name,
            landing_company_shortcode => $landing_company->short,
        }};
}

1;
