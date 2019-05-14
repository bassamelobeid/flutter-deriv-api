#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use Try::Tiny;
use Email::Valid;
use List::MoreUtils qw( uniq any firstval );
use HTML::Entities;
use Format::Util::Strings qw( defang );
use Text::Trim;
use Date::Utility;

use f_brokerincludeall;
use BOM::User::Client;
use BOM::User;
use BOM::Database::Model::UserConnect;
use BOM::Config::Runtime;
use BOM::Platform::Event::Emitter;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use BOM::DualControl;
use BOM::User::AuditLog;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Client's Email Details");
Bar("View / Edit Client's Email");

my $clerk = BOM::Backoffice::Auth0::get_staffname();
my $now   = Date::Utility->new;

my %input         = %{request()->params};
my $email         = trim(lc defang($input{email}));
my $encoded_email = encode_entities($email);

my $new_email;
my $encoded_new_email;
if ($input{new_email}) {
    $new_email         = trim(lc defang($input{new_email}));
    $encoded_new_email = encode_entities($new_email);
    if (not Email::Valid->address($new_email)) {
        print "invalid email format [$encoded_new_email]";
        code_exit_BO();
    }
}

my $user = BOM::User->new(email => $email);
if (not $user) {
    print "<p>ERROR: Clients with email <b>$encoded_email</b> not found.</p>";
    code_exit_BO();
}

my @mt_logins_ids = sort grep { /^MT\d+$/ } $user->loginids;
my @bom_login_ids = $user->bom_loginids();
my @bom_logins;

foreach my $lid (sort @bom_login_ids) {
    my $client = BOM::User::Client->new({loginid => $lid});
    push @bom_logins,
        {
        text     => encode_entities($lid),
        currency => ' (' . ($client->default_account ? $client->default_account->currency_code : 'No currency selected') . ')',
        style => ($client->status->disabled ? ' style=color:red' : '')};
}

if (not $input{email_edit}) {
    # list loginids with email
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_email.html.tt',
        {
            list         => 1,
            email        => $email,
            bom_logins   => [@bom_logins],
            mt5_loginids => [@mt_logins_ids]
        },
    ) || die BOM::Backoffice::Request::template()->error();

    code_exit_BO();
}

unless ($input{transtype}) {
    print "Please select transaction type";
    code_exit_BO();
}
my $error = BOM::DualControl->new({
        staff           => $clerk,
        transactiontype => $input{transtype}})->validate_client_control_code($input{DCcode}, $new_email, $user->{id});
if ($error) {
    print $error->get_mesg();
    code_exit_BO();
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
            $user->update_has_social_signup(0);
            #remove all other social accounts
            my $user_connect = BOM::Database::Model::UserConnect->new;
            my @providers    = $user_connect->get_connects_by_user_id($user->{id});
            $user_connect->remove_connect($user->{id}, $_) for @providers;
            $had_social_signup = "(from social signup)";
        }

        $user->update_email_fields(email => $new_email);

        foreach my $lid ($user->loginids) {
            next unless $lid !~ /^MT\d+$/;
            my $client_obj = BOM::User::Client->new({loginid => $lid});
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
        . " updated user $email "
        . $had_social_signup
        . " to $new_email by clerk=$clerk (DCcode="
        . $input{DCcode}
        . ") $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, $new_email, $clerk);

    my $default_client_loginid = $user->get_default_client->loginid;
    BOM::Platform::Event::Emitter::emit('sync_user_to_MT5',    {loginid => $default_client_loginid});
    BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $default_client_loginid});
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_email.html.tt',
        {
            updated      => 1,
            old_email    => $email,
            new_email    => $new_email,
            bom_logins   => [@bom_logins],
            mt5_loginids => [@mt_logins_ids]
        },
    ) || die BOM::Backoffice::Request::template()->error();
} else {
    print "Same email [$new_email] provided, no update required";
}

code_exit_BO();

1;
