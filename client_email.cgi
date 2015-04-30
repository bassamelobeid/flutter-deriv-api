#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use Try::Tiny;
use Email::Valid;
use List::MoreUtils qw( uniq any firstval );

use f_brokerincludeall;
use BOM::Utility::Format::Strings qw( defang );
use Text::Trim;
use BOM::Platform::User;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use BOM::Platform::Email qw(send_email);
use BOM::Database::ClientDB;
use BOM::Database::UserDB;

BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("Client's Email Details");
Bar("View / Edit Client's Email");

my $staff  = BOM::Platform::Auth0::can_access(['CS']);
my $clerk  = BOM::Platform::Auth0::from_cookie()->{nickname};

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
} elsif ($input{email_edit} == 1) {
    if ($email ne $new_email) {
        my ($delete_old_user, $duplicate_broker);
        my @loginids_new;
        my $user_new = BOM::Platform::User->new({ email => $new_email });

        # if new email already exist in db, check whether that user already has account with same broker. If not, allow changes
        if ($user_new->id) {
            $delete_old_user = 1;
            @loginids_new = $user_new->loginid_array;
            my @brokers_new = uniq map { /^(\D+)\d+$/ ? my $x = $1 : () } @loginids_new;

            foreach my $loginid (@loginids) {
                my $broker;
                $loginid =~ /^(\D+)\d+$/ and $broker = $1;

                if ($broker and (any { $broker eq $_ } @brokers_new)) {
                    $duplicate_broker = $broker;
                    last;
                }
            }
        }

        if (not $duplicate_broker) {
            try {
                if (not $delete_old_user) {
                    $user->email($new_email);
                    $user->save;
                } else {
                    my $dbh = BOM::Database::UserDB::rose_db()->dbh;
                    $dbh->{AutoCommit} = 0;
                    my $update = q{
                        UPDATE users.loginid SET binary_user_id = ?
                        WHERE binary_user_id = ?
                    };
                    my $sth = $dbh->prepare($update);
                    $sth->execute($user_new->id, $user->id);

                    my $delete = q{ DELETE FROM users.binary_user WHERE id = ? };
                    my $sth = $dbh->prepare($delete);
                    $sth->execute($user->id);

                    $dbh->commit;
                }

                foreach my $loginid (@loginids) {
                    my $broker;
                    $loginid =~ /^(\D+)\d+$/ and $broker = $1;

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

            @loginids = (@loginids, @loginids_new) if (@loginids_new > 1);
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
            my $l = firstval { $_ =~ qr/^$duplicate_broker\d+$/ } @loginids_new;

            print "Update email for user $email failed, [$new_email] already has loginid [$l]";
            code_exit_BO();
        }
    } else {
        print "Same email [$new_email] provided, no update required";
    }
} elsif ($input{email_edit} == 2) {
    my $loginid = trim(uc $input{loginid});

    if ($email ne $new_email) {
        my $user_dbh = BOM::Database::UserDB::rose_db()->dbh;
        $user_dbh->{AutoCommit} = 0;
        my $update = q{
            UPDATE users.loginid SET binary_user_id = ?
            WHERE loginid = ?
        };
        my $user_sth = $user_dbh->prepare($update);

        my $broker;
        $loginid =~ /^(\D+)\d+$/ and $broker = $1;
        my $client_dbh = BOM::Database::ClientDB->new({
                broker_code => $broker,
            })->db->dbh;
        my $client_sth = $client_dbh->prepare(q{
                UPDATE betonmarkets.client
                SET email = $1
                WHERE loginid = $2
            });

        my $user_new = BOM::Platform::User->new({ email => $new_email });
        if (not $user_new->id) {
            $user_new->password($user->password);
            $user_new->save;

            $user_sth->execute($user_new->id, $loginid);
            $client_sth->execute($new_email, $loginid);
        } else {
            my @loginids_new = $user_new->loginid_array;
            my @brokers_new = uniq map { /^(\D+)\d+$/ ? my $x = $1 : () } @loginids_new;

            if ($broker and (any { $broker eq $_ } @brokers_new)) {
                my $l = firstval { $_ =~ qr/^$broker\d+$/ } @loginids_new;
                print "Update email for client [$loginid] failed, new email [$new_email] already has loginid with [$l]";
                code_exit_BO();
            } else {
                $user_sth->execute($user_new->id, $loginid);
                $client_sth->execute($new_email, $loginid);
            }
        }

        # check old email still has any loginid. If not, delete it
        my $cnt_sth = $user_dbh->prepare(q{
            SELECT count(*) FROM users.loginid l, users.binary_user u
            WHERE l.binary_user_id = u.id AND email = ?
        });
        $cnt_sth->execute($email);
        my $count = $cnt_sth->fetchrow_arrayref();

        unless ($count and $count->[0] > 0) {
            my $del_sth = $user_dbh->prepare(q{ DELETE FROM users.binary_user WHERE email = ? });
            $del_sth->execute($email);
        }
        $user_dbh->commit;
        $user_dbh->{AutoCommit} = 1;

        BOM::Platform::Context::template->process(
            'backoffice/client_email.html.tt',
            {
                updated     => 1,
                old_email   => $email,
                new_email   => $new_email,
                loginids    => [$loginid],
            },
        ) || die BOM::Platform::Context::template->error();
    } else {
        print "Same email [$new_email] provided, no update required";
    }
}

code_exit_BO();

1;
