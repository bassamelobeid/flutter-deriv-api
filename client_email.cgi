#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use Try::Tiny;
use Email::Valid;
use List::MoreUtils qw( uniq any firstval );

use f_brokerincludeall;
use Format::Util::Strings qw( defang );
use Text::Trim;
use Path::Tiny;
use Date::Utility;
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use BOM::Platform::Email qw(send_email);
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use BOM::DualControl;
use BOM::System::AuditLog;

BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("Client's Email Details");
Bar("View / Edit Client's Email");

my $staff  = BOM::Platform::Auth0::can_access(['CS']);
my $clerk  = BOM::Platform::Auth0::from_cookie()->{nickname};
my $now    = Date::Utility->new;

my %input = %{request()->params};
my $email = trim(lc defang($input{email}));

my @emails = ($email);

my $new_email;
if ($input{new_email}) {
    $new_email = trim(lc defang($input{new_email}));
    push @emails, $new_email;
}

foreach my $item (@emails) {
    if (not Email::Valid->address($item)) {
        print "invalid email format [$item]";
        code_exit_BO();
    }
}

my $user = BOM::Platform::User->new({ email => $email });
if (not $user->id) {
    my $self_href = request()->url_for('backoffice/client_email.cgi');
    print "<p>ERROR: Clients with email <b>$email</b> not found.</p>";
    code_exit_BO();
};

my @loginids = $user->loginid_array;
if (not $input{email_edit}) {
    # list loginids with email
    BOM::Platform::Context::template->process(
        'backoffice/client_email.html.tt',
        {
            list        => 1,
            email       => $email,
            loginids    => \@loginids,
        },
    ) || die BOM::Platform::Context::template->error();

    code_exit_BO();
}

unless ($input{transtype}) {
    print "Please select transaction type";
    code_exit_BO();
}
my $error = BOM::DualControl->new({staff => $clerk, transactiontype => $input{transtype}})->validate_client_control_code($input{DCcode}, $new_email);
if ($error) {
    print $error->get_mesg();
    code_exit_BO();
}

if ($email ne $new_email) {
    my $user_new = BOM::Platform::User->new({ email => $new_email });
    if ($user_new->id) {
        print "Email update not allowed, as same email [$new_email] already exists in system";
        code_exit_BO();
    }

    try {
        $user->email($new_email);
        $user->save;

        foreach my $loginid (@loginids) {
            my $client = BOM::Platform::Client::get_instance({loginid => $loginid});
            $client->email($new_email);
            $client->save;
        }
    } catch {
        print "Update email for user $email failed, reason: [$_]";
        code_exit_BO();
    };

    my $msg = $now->datetime . " " . $input{transtype} .  " updated $email to $new_email for @loginids by clerk=$clerk (DCcode=" . $input{DCcode} . ") $ENV{REMOTE_ADDR}";
    BOM::System::AuditLog::log($msg, $new_email, $clerk);
    Path::Tiny::path("/var/log/fixedodds/fclientdetailsupdate.log")->append($msg);

    BOM::Platform::Context::template->process(
        'backoffice/client_email.html.tt',
        {
            updated     => 1,
            old_email   => $email,
            new_email   => $new_email,
            loginids    => \@loginids,
        },
    ) || die BOM::Platform::Context::template->error();
} else {
    print "Same email [$new_email] provided, no update required";
}

code_exit_BO();

1;
