#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use Date::Utility;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Platform::Event::Emitter;
use Data::Dump qw(pp);

BOM::Backoffice::Sysinit::init();

my $cgi   = CGI->new;
my %input = %{request()->params};
my $staff = BOM::Backoffice::Auth0::get_staffname();

PrintContentType();
BrokerPresentation('CFD Account Management');

# Display a message and provide a link to go back
sub go_back {
    my $args    = shift;
    my $message = $args->{message};
    my $color   = ($args->{error} ? 'red' : 'green');

    print qq~<p style="font-size:15px;color: var(--color-$color);">$message</p> <br> <p><a href="~
        . request()->url_for('backoffice/quant/cfd_account_management.cgi')
        . qq~">&laquo;Return to CFD Account Management</a></p>~;
}

if ($input{action} and $input{action} eq 'restore_archived_MT5') {
    my $archived_mt5 = $input{archived_mt5_accounts};
    $archived_mt5 =~ s/\s+//g;
    my @mt5_accounts = split(',', uc($archived_mt5 || ''));

    unless (@mt5_accounts) {
        go_back({message => 'No MT5 Accounts Found!', error => 1});
        code_exit_BO();
    }

    @mt5_accounts = uniq(@mt5_accounts);
    my @invalid_mt5 = @{BOM::MT5::BOUtility::valid_mt5_check(\@mt5_accounts)};

    if (@invalid_mt5) {
        my $display_msg = 'Submission Halted: Incorrect MT5 Account Detected <br>' . join(', ', @invalid_mt5);
        go_back({message => $display_msg, error => 1});
        code_exit_BO();
    }

    BOM::Platform::Event::Emitter::emit('mt5_archive_restore_sync', {mt5_accounts => \@mt5_accounts});
    my $msg = Date::Utility->new->datetime . " Restore and sync archived MT5 is requested by clerk=$staff $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, undef, $staff);

    Bar('RESTORE MT5 ACCOUNT AND SYNC STATUS');
    my $display_msg = "Successfully requested restore and sync status of archived MT5 accounts";
    go_back({message => $display_msg});

    code_exit_BO();
}

if ($input{action} and $input{action} eq 'archive_MT5_accounts') {
    my $mt5_accounts_input = $input{mt5_accounts_input};
    $mt5_accounts_input =~ s/\s+//g;
    my @mt5_accounts = split(',', uc($mt5_accounts_input || ''));

    unless (@mt5_accounts) {
        go_back({message => 'No MT5 Accounts Found!', error => 1});
        code_exit_BO();
    }

    @mt5_accounts = uniq(@mt5_accounts);
    my @invalid_mt5 = @{BOM::MT5::BOUtility::valid_mt5_check(\@mt5_accounts)};

    if (@invalid_mt5) {
        my $display_msg = 'Submission Halted: Incorrect MT5 Account Detected <br>' . join(', ', @invalid_mt5);
        go_back({message => $display_msg, error => 1});
        code_exit_BO();
    }

    BOM::Platform::Event::Emitter::emit('mt5_archive_accounts', {loginids => \@mt5_accounts});
    my $msg =
        Date::Utility->new->datetime . " Archival of MT5 accounts " . join(', ', @mt5_accounts) . " requested by clerk=$staff $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, undef, $staff);

    Bar('ARCHIVE MT5 ACCOUNTS');
    my $display_msg = "Successfully requested archival of the MT5 accounts. An email will be sent once the request is satisfied";
    go_back({message => $display_msg});
    code_exit_BO();
}

Bar("Restore MT5 Account and Sync Status", {nav_link => "Restore Archived MT5 Account"});
print qq~
    <p>MT5 archived accounts to restore and sync database status to active: </p>
    <form action="~ . request()->url_for('backoffice/quant/cfd_account_management.cgi') . qq~" method="get">
        <input type="hidden" name="action" value="restore_archived_MT5">
        <div class="row">
            <label>FROM MT5:</label>
            <input type="text" size="60" name="archived_mt5_accounts" placeholder="[Example: MTR123456, MTR654321] (comma separate accounts)" data-lpignore="true" maxlength="500" required/>
        </div>
        <input type="submit" class="btn btn--primary" value="Restore MT5 Accounts">
    </form>~;

Bar("Archive MT5 Account", {nav_link => "Archive MT5 Account"});
print qq~
    <p>MT5 accounts to archive: </p>
    <form action="~ . request()->url_for('backoffice/quant/cfd_account_management.cgi') . qq~" method="get">
        <input type="hidden" name="action" value="archive_MT5_accounts">
        <div class="row">
            <label>FROM MT5:</label>
            <input type="text" size="60" name="mt5_accounts_input" placeholder="[Example: MTR123456, MTR654321] (comma separate accounts)" data-lpignore="true" maxlength="500" required/>
        </div>
        <input type="submit" class="btn btn--primary" value="Archive MT5 Accounts">
    </form>~;

code_exit_BO();
