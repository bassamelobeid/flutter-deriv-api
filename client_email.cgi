#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use Try::Tiny;
use Email::Valid;
use List::MoreUtils qw( uniq any firstval );
use HTML::Entities;

use f_brokerincludeall;
use Format::Util::Strings qw( defang );
use Text::Trim;
use Date::Utility;
use BOM::User::Client;
use BOM::User;
use BOM::Database::Model::UserConnect;
use BOM::Config::Runtime;
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

my $clerk = BOM::Backoffice::Auth0::from_cookie()->{nickname};
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

my $user = BOM::User->new({email => $email});
if (not $user) {
    print "<p>ERROR: Clients with email <b>$encoded_email</b> not found.</p>";
    code_exit_BO();
}

my @all_loginids = map { $_->loginid } $user->loginid;
if (not $input{email_edit}) {
    # list loginids with email
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_email.html.tt',
        {
            list         => 1,
            email        => $email,
            bom_loginids => [grep { $_ !~ /^MT\d+$/ } @all_loginids],
            mt5_loginids => [grep { $_ =~ /^MT\d+$/ } @all_loginids],
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
        transactiontype => $input{transtype}})->validate_client_control_code($input{DCcode}, $new_email, $user->id);
if ($error) {
    print $error->get_mesg();
    code_exit_BO();
}

if ($email ne $new_email) {
    if (BOM::User->new({email => $new_email})) {
        print "Email update not allowed, as same email [$encoded_new_email] already exists in system";
        code_exit_BO();
    }

    my $had_social_signup = '';

    try {
        # remove social signup flag also add note to audit log.
        if ($user->has_social_signup) {
            $user->has_social_signup(undef);
            #remove all other social accounts
            my $user_connect = BOM::Database::Model::UserConnect->new;
            my @providers    = $user_connect->get_connects_by_user_id($user->id);
            $user_connect->remove_connect($user->id, $_) for @providers;
            $had_social_signup = "(from social signup)";
        }

        $user->email($new_email);
        $user->save;

        foreach my $lid ($user->loginid) {
            next unless $lid->loginid !~ /^MT\d+$/;
            my $client_obj = BOM::User::Client->new({loginid => $lid->loginid});
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

    BOM::Backoffice::Request::template()->process(
        'backoffice/client_email.html.tt',
        {
            updated      => 1,
            old_email    => $email,
            new_email    => $new_email,
            bom_loginids => [grep { $_ !~ /^MT\d+$/ } @all_loginids],
            mt5_loginids => [grep { $_ =~ /^MT\d+$/ } @all_loginids],
        },
    ) || die BOM::Backoffice::Request::template()->error();
} else {
    print "Same email [$new_email] provided, no update required";
}

code_exit_BO();

1;
