#!/etc/rmg/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use Try::Tiny;
use Email::Valid;
use List::MoreUtils qw( uniq any firstval );
use HTML::Entities;

use f_brokerincludeall;
use Format::Util::Strings qw( defang );
use Text::Trim;
use Date::Utility;
use Client::Account;
use BOM::Platform::User;
use BOM::Platform::Runtime;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use BOM::DualControl;
use BOM::System::AuditLog;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Client's Email Details");
Bar("View / Edit Client's Email");

my $staff = BOM::Backoffice::Auth0::can_access(['CS']);
my $clerk = BOM::Backoffice::Auth0::from_cookie()->{nickname};
my $now   = Date::Utility->new;

my %input = %{request()->params};
my $email = trim(lc defang($input{email}));
my $encoded_email = encode_entities($email);

my $new_email;
my $encoded_new_email;
if ($input{new_email}) {
    $new_email = trim(lc defang($input{new_email}));
    $encoded_new_email = encode_entities($new_email);
    if (not Email::Valid->address($new_email)) {
        print "invalid email format [$encoded_new_email]";
        code_exit_BO();
    }
}

my $user = BOM::Platform::User->new({email => $email});
if (not $user) {
    my $self_href = request()->url_for('backoffice/client_email.cgi');
    print "<p>ERROR: Clients with email <b>$encoded_email</b> not found.</p>";
    code_exit_BO();
}

if (not $input{email_edit}) {
    # list loginids with email
    BOM::Backoffice::Request::template->process(
        'backoffice/client_email.html.tt',
        {
            list     => 1,
            email    => $email,
            loginids => [map {$_->loginid} $user->loginid],
        },
    ) || die BOM::Backoffice::Request::template->error();

    code_exit_BO();
}

unless ($input{transtype}) {
    print "Please select transaction type";
    code_exit_BO();
}
my $error = BOM::DualControl->new({
        staff           => $clerk,
        transactiontype => $input{transtype}})->validate_client_control_code($input{DCcode}, $new_email);
if ($error) {
    print $error->get_mesg();
    code_exit_BO();
}

if ($email ne $new_email) {
    if (BOM::Platform::User->new({email => $new_email})) {
        print "Email update not allowed, as same email [$encoded_new_email] already exists in system";
        code_exit_BO();
    }

    try {
        $user->email($new_email);
        $user->save;

        foreach my $client_obj ($user->clients(disabled_ok => 1)) {
            $client_obj->email($new_email);
            $client_obj->save;
        }
    }
    catch {
        print "Update email for user $encoded_email failed, reason: [" . encode_entities($_) . "]";
        code_exit_BO();
    };

    my $msg =
          $now->datetime . " "
        . $input{transtype}
        . " updated user $email to $new_email by clerk=$clerk (DCcode="
        . $input{DCcode}
        . ") $ENV{REMOTE_ADDR}";
    BOM::System::AuditLog::log($msg, $new_email, $clerk);

    BOM::Backoffice::Request::template->process(
        'backoffice/client_email.html.tt',
        {
            updated   => 1,
            old_email => $email,
            new_email => $new_email,
            loginids  => [map {$_->loginid} $user->loginid],
        },
    ) || die BOM::Backoffice::Request::template->error();
} else {
    print "Same email [$new_email] provided, no update required";
}

code_exit_BO();

1;
