#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use Try::Tiny;
use Email::Valid;

use f_brokerincludeall;
use BOM::Utility::Format::Strings qw( defang );
use BOM::Platform::User;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use BOM::Platform::Email qw(send_email);
use BOM::Database::ClientDB;

BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("Client's Email Details");
Bar("View / Edit Client's Email");

my $staff  = BOM::Platform::Auth0::can_access(['CS']);
my $clerk  = BOM::Platform::Auth0::from_cookie()->{nickname};

my %input = %{request()->params};
my $email = lc defang($input{email});

my @emails = ($email);

my $new_email;
if ($input{new_email}) {
    $new_email = lc defang($input{new_email});
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
    print "<p>ERROR: Clients with email [$email] not found. <br> Please try again: $self_href</p>";
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
} else {
    if ($email ne $new_email) {
        try {
            $user->email($new_email);
            $user->save;

            foreach my $loginid (@loginids) {
                $loginid =~ /(\D+)\d+/;
                my $broker = $1;

                my $dbh = BOM::Database::ClientDB->new({
                        broker_code => $broker,
                    })->db->dbh;

                my $sth = $dbh->prepare(q{
                        UPDATE betonmarkets.client
                        SET email = $1
                        WHERE loginid = $2
                    });
                $sth->bind_param(1, $new_email);
                $sth->bind_param(2, $loginid);
                $sth->execute();
            }
        } catch {
            print "Update email for user $email failed, reason: [$_]";
            code_exit_BO();
        };

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
}

code_exit_BO();

1;
