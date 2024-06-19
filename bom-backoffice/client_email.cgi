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
use BOM::Backoffice::UserService;
use BOM::Service;
use Log::Any qw($log);

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Client's Email Details");

my $title = "View / Edit Client's Email";

my $clerk = BOM::Backoffice::Auth::get_staffname();
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

    code_exit_BO("<p>ERROR: Invalid email format [$encoded_new_email]<p> $retry_form", $title) unless Email::Valid->address($encoded_new_email);
}

unless ($email) {
    code_exit_BO("<p>ERROR: Email address is required<p> $retry_form", $title);
}

my $user_data = BOM::Service::user(
    context    => BOM::Backoffice::UserService::get_context(),
    command    => 'get_attributes',
    user_id    => $email,
    attributes => [qw(id has_social_signup default_client)],
);

unless ($user_data->{status} eq 'ok') {
    code_exit_BO("<p>ERROR: Clients with email <b>$encoded_email</b> not found.</p> $retry_form", $title);
}
my $user_attributes = $user_data->{attributes};

Bar($title);

my $logins             = loginids($user_attributes->{id});
my $mt_logins_ids      = $logins->{mt5};
my $bom_logins         = $logins->{bom};
my $dx_logins_ids      = $logins->{dx};
my $derivez_logins_ids = $logins->{derivez};
my $ctrader_logins_ids = $logins->{ctrader};

if (not $input{email_edit}) {
    # list loginids with email
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_email.html.tt',
        {
            list             => 1,
            email            => $email,
            bom_logins       => $bom_logins,
            mt5_loginids     => $mt_logins_ids,
            dx_loginids      => $dx_logins_ids,
            derivez_loginids => $derivez_logins_ids,
            ctrader_loginids => $ctrader_logins_ids,
        },
    ) || die BOM::Backoffice::Request::template()->error(), "\n";

    code_exit_BO();
}

unless ($input{transtype}) {
    print "Please select transaction type";
    code_exit_BO();
}

if ($email ne $new_email) {
    my $check_email = BOM::Service::user(
        context    => BOM::Backoffice::UserService::get_context(),
        command    => 'get_attributes',
        user_id    => $new_email,
        attributes => [qw(binary_user_id)],
    );

    if ($check_email->{status} eq 'ok') {
        print "Email update not allowed, as same email [$encoded_new_email] already exists in system";
        code_exit_BO();
    }

    my $had_social_signup = '';

    # User service will handle the unlinking of accounts, add to log
    $had_social_signup = "(from social signup)" if ($user_attributes->{has_social_signup});

    my $dcc_code = $input{DCcode};
    my $error    = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input{transtype}})->validate_client_control_code($dcc_code, $new_email, $user_attributes->{id});

    if ($error) {
        print $error->get_mesg();
        code_exit_BO();
    }

    $user_data = BOM::Service::user(
        context    => BOM::Backoffice::UserService::get_context,
        command    => 'update_attributes_force',
        user_id    => $email,
        attributes => {email => $new_email},
    );

    unless ($user_data->{status} eq 'ok') {
        print "Update email for user $encoded_email failed, reason: [" . encode_entities($user_data->{message}) . "]";
        code_exit_BO();
    }

    my $msg =
        $now->datetime . " " . $input{transtype} . " updated user $email " . $had_social_signup . " to $new_email by clerk=$clerk $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, $new_email, $clerk);
    #CS: for every email address change request, we will disable the client's
    #    account and once receiving a confirmation from his new email address, we will change it and enable the account.

    BOM::Backoffice::Request::template()->process(
        'backoffice/client_email.html.tt',
        {
            updated          => 1,
            old_email        => $email,
            new_email        => $new_email,
            bom_logins       => $bom_logins,
            mt5_loginids     => $mt_logins_ids,
            dx_loginids      => $dx_logins_ids,
            derivez_loginids => $derivez_logins_ids,
            ctrader_loginids => $ctrader_logins_ids,
        },
    ) || die BOM::Backoffice::Request::template()->error(), "\n";
} else {
    print "Same email [$new_email] provided, no update required";
}

code_exit_BO();

1;
