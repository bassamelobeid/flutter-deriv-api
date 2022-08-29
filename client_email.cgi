#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use Syntax::Keyword::Try;
use Email::Valid;
use List::MoreUtils qw( uniq any firstval );
use HTML::Entities;
use Format::Util::Strings qw( defang );
use Format::Util::Numbers qw/ formatnumber /;
use Text::Trim;
use Date::Utility;

use f_brokerincludeall;
use BOM::User::Client;
use BOM::User;
use BOM::Database::Model::UserConnect;
use BOM::Config::Runtime;
use BOM::Platform::Event::Emitter;
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit      ();
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use BOM::DualControl;
use BOM::User::AuditLog;
use Log::Any qw($log);

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Client's Email Details");

my $title = "View / Edit Client's Email";

my $clerk = BOM::Backoffice::Auth0::get_staffname();
my $now   = Date::Utility->new;

my %input         = %{request()->params};
my $email         = trim(lc defang($input{email}));
my $encoded_email = encode_entities($email);

my $retry_form = qq[
        <form method="get">
            Email: <input type="text" name="email" value="$encoded_email" size="30" placeholder="email\@domain.com" data-lpignore="true" />
        </form>];

my $new_email;
my $encoded_new_email;
if ($input{new_email}) {
    $new_email         = trim(lc defang($input{new_email}));
    $encoded_new_email = encode_entities($new_email);
}

for my $email_address ($email, $new_email) {
    next unless $email_address;
    my $encoded_value = encode_entities($email_address);
    if (not Email::Valid->address($email_address)) {
        code_exit_BO("<p>ERROR: Invalid email format [$encoded_value]<p> $retry_form", $title);
    }
}

unless ($email) {
    code_exit_BO("<p>ERROR: Email address is required<p> $retry_form", $title);
}

my $user = BOM::User->new(email => $email);
if (not $user) {
    code_exit_BO("<p>ERROR: Clients with email <b>$encoded_email</b> not found.</p> $retry_form", $title);
}

Bar($title);

my $logins            = loginids($user);
my $mt_logins_ids     = $logins->{mt5};
my $bom_logins        = $logins->{bom};
my $dx_logins_ids     = $logins->{dx};
my $is_client_only_cr = 0;
my $dcc_code;

if (@$mt_logins_ids == 0 && @$dx_logins_ids == 0) {
    $is_client_only_cr = 1;
    foreach my $login_id ($user->bom_real_loginids) {
        if (LandingCompany::Registry->broker_code_from_loginid($login_id) ne 'CR') {
            $is_client_only_cr = 0;
            last;
        }
    }
}

if (not $input{email_edit}) {
    # list loginids with email
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_email.html.tt',
        {
            list              => 1,
            email             => $email,
            bom_logins        => $bom_logins,
            mt5_loginids      => $mt_logins_ids,
            dx_loginids       => $dx_logins_ids,
            is_client_only_cr => $is_client_only_cr,
        },
    ) || die BOM::Backoffice::Request::template()->error(), "\n";

    code_exit_BO();
}

unless ($input{transtype}) {
    print "Please select transaction type";
    code_exit_BO();
}

if (!$is_client_only_cr) {
    $dcc_code = $input{DCcode};
    my $error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input{transtype}})->validate_client_control_code($dcc_code, $new_email, $user->{id});
    if ($error) {
        print $error->get_mesg();
        code_exit_BO();
    }
} else {
    $dcc_code = "N/A";
    unless ($new_email) {
        print "New email address is not provided";
        code_exit_BO();
    }
}

if ($email ne $new_email) {
    if (BOM::User->new(email => $new_email)) {
        print "Email update not allowed, as same email [$encoded_new_email] already exists in system";
        code_exit_BO();
    }

    my $had_social_signup = '';

    try {
        # remove social signup flag also add note to audit log.
        if ($user->{has_social_signup}) {
            $user->unlink_social;
            $had_social_signup = "(from social signup)";
        }

        $user->update_email($new_email);

        foreach my $login_id ($user->bom_loginids) {
            unless (LandingCompany::Registry->check_broker_from_loginid($login_id)) {
                $log->warnf("Invalid login id $login_id");
                next;
            }

            my $client_obj = BOM::User::Client->new({loginid => $login_id});
            $client_obj->email($new_email);
            $client_obj->save;
        }
    } catch ($e) {
        print "Update email for user $encoded_email failed, reason: [" . encode_entities($e) . "]";
        code_exit_BO();
    }

    my $msg =
          $now->datetime . " "
        . $input{transtype}
        . " updated user $email "
        . $had_social_signup
        . " to $new_email by clerk=$clerk (DCcode="
        . $dcc_code
        . ") $ENV{REMOTE_ADDR}";

    BOM::User::AuditLog::log($msg, $new_email, $clerk);
    #CS: for every email address change request, we will disable the client's
    #    account and once receiving a confirmation from his new email address, we will change it and enable the account.
    my $default_client = $user->get_default_client(
        include_disabled   => 1,
        include_duplicated => 1
    );
    my $default_client_loginid = $default_client->loginid;

    BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $default_client_loginid});

    unless ($default_client->is_virtual) {
        BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $default_client_loginid});
    }

    BOM::Backoffice::Request::template()->process(
        'backoffice/client_email.html.tt',
        {
            updated           => 1,
            old_email         => $email,
            new_email         => $new_email,
            bom_logins        => $bom_logins,
            mt5_loginids      => $mt_logins_ids,
            dx_loginids       => $dx_logins_ids,
            is_client_only_cr => $is_client_only_cr,
        },
    ) || die BOM::Backoffice::Request::template()->error(), "\n";
} else {
    print "Same email [$new_email] provided, no update required";
}

code_exit_BO();

1;
