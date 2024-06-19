#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use Date::Utility;
use HTML::Entities;
use Text::CSV;
use CGI;
use Brands;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Platform::Event::Emitter;

BOM::Backoffice::Sysinit::init();

my $cgi   = CGI->new;
my %input = %{request()->params};
my $staff = BOM::Backoffice::Auth::get_staffname();

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
        my $display_msg =
            scalar(@invalid_mt5) > 20
            ? 'Submission Halted: Too many incorrect MT5 accounts detected <br>' . join('', @invalid_mt5[0 .. 19]) . '...'
            : 'Submission Halted: Incorrect MT5 Account Detected <br>' . join('', @invalid_mt5);

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

    if ($input{loginids_csv_for_archival}) {
        my $csv   = Text::CSV->new();
        my $file  = $cgi->upload('loginids_csv_for_archival');
        my $lines = $csv->getline_all($file);
        shift @$lines;

        foreach my $line (@$lines) {
            push @mt5_accounts, $line->[0];
        }

        close $file;
    }

    unless (@mt5_accounts) {
        go_back({message => 'No MT5 Accounts Found!', error => 1});
        code_exit_BO();
    }

    @mt5_accounts = uniq(@mt5_accounts);
    my @invalid_mt5 = @{BOM::MT5::BOUtility::valid_mt5_check(\@mt5_accounts)};

    if (@invalid_mt5) {
        my $display_msg =
            scalar(@invalid_mt5) > 20
            ? 'Submission Halted: Too many incorrect MT5 accounts detected <br>' . join('', @invalid_mt5[0 .. 19]) . '...'
            : 'Submission Halted: Incorrect MT5 Account Detected <br>' . join('', @invalid_mt5);

        go_back({message => $display_msg, error => 1});
        code_exit_BO();
    }

    my $brands = Brands->new();
    BOM::Platform::Event::Emitter::emit(
        'mt5_archive_accounts',
        {
            loginids    => \@mt5_accounts,
            email_title => 'MT5 Account Archival Request from Backoffice',
            email_to    => $brands->emails('quants') . ', ' . $brands->emails('compliance_regs'),
            staff_name  => $staff,
        });

    my $msg =
        Date::Utility->new->datetime . " Archival of MT5 accounts " . join(', ', @mt5_accounts) . " requested by clerk=$staff $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, undef, $staff);

    Bar('ARCHIVE MT5 ACCOUNTS');
    my $display_msg =
        "Successfully requested archival of the MT5 accounts. An email will be sent once the request is satisfied. For large csv files some delay is expected.";
    go_back({message => $display_msg});
    code_exit_BO();
}

if ($input{action} and $input{action} eq 'jurisdiction_MT5_accounts_status_resync') {
    my $client_loginids_input = $input{client_loginids_input};
    $client_loginids_input =~ s/\s+//g;
    my @client_loginids = split(',', uc($client_loginids_input || ''));

    # read the csv uploaded that reference by client_loginids_csv, process each row of data inside and save it to @client_loginids without including header
    if ($input{client_loginids_csv}) {
        my $csv   = Text::CSV->new();
        my $file  = $cgi->upload('client_loginids_csv');
        my $lines = $csv->getline_all($file);
        shift @$lines;
        foreach my $line (@$lines) {
            push @client_loginids, $line->[0];
        }

        close $file;
    }

    unless (@client_loginids) {
        go_back({message => 'No Client Loginids Found!', error => 1});
        code_exit_BO();
    }

    @client_loginids = uniq(@client_loginids);

    foreach my $client_loginid (@client_loginids) {
        BOM::Platform::Event::Emitter::emit('sync_mt5_accounts_status', {client_loginid => $client_loginid});
    }

    my $msg =
          Date::Utility->new->datetime
        . "Client MT5 accounts jurisdiction resync "
        . join(', ', @client_loginids)
        . " requested by clerk=$staff $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, undef, $staff);

    Bar('Client MT5 Accounts Jurisdiction Status Re-Synchronization');
    my $display_msg = "Successfully requested Client MT5 Accounts Jurisdiction Status Re-Synchronization.";
    go_back({message => $display_msg});
    code_exit_BO();
}

print qq~
    <script>
        function checkCSV(evt, max_size) {
            var file = evt.target.files[0];
            if (file.type !== 'text/csv') {
                alert('Unsupported file format. Please upload a CSV file.');
                evt.target.value = '';
                return;
            }
            if (file.size > max_size) {
                alert('This file is too large. Please upload a smaller file.');
                evt.target.value = '';
                return;
            }
        }
    </script>~;

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
    <form action="~ . request()->url_for('backoffice/quant/cfd_account_management.cgi') . qq~" method='POST' enctype='multipart/form-data'>
        <input type="hidden" name="action" value="archive_MT5_accounts">
        <div class="row">
            <label>FROM MT5:</label>
            <input type="text" size="60" name="mt5_accounts_input" placeholder="[Example: MTR123456, MTR654321] (comma separate accounts)" data-lpignore="true" maxlength="500"/>
        </div>
        <div class="row">
        <label>CSV option available. Format required as shown below:</label>
        </div>
        <div class="row">
        <table>
            <thead>
                <tr>
                    <th style="text-transform: none;">loginid</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td>MTR12345</td>
                </tr>
                <tr>
                    <td>MTR23456</td>
                </tr>
            </tbody>
        </table>
        </div>
        <div class="row">
        <label>Upload CSV(Max 1MB):</label>
            <input type="file" name="loginids_csv_for_archival" onchange="checkCSV(event, 1048576)" accept=".csv"/>
        </div>
        <input type="submit" class="btn btn--primary" value="Archive MT5 Accounts">
    </form>~;

Bar("Client MT5 Accounts Jurisdiction Status Re-Synchronization", {nav_link => "MT5 Jurisdiction Status Re-Syncronization"});
print qq~
    <p>Client loginid to synchronize linked MT5 account: </p>
    <form action="~ . request()->url_for('backoffice/quant/cfd_account_management.cgi') . qq~" method='POST' enctype='multipart/form-data'>
        <input type="hidden" name="action" value="jurisdiction_MT5_accounts_status_resync">
        <div class="row">
            <label>Client to Process:</label>
            <input type="text" size="60" name="client_loginids_input" placeholder="[Example: CR123456, CR654321] (comma separate accounts)" data-lpignore="true" maxlength="500"/>
        </div>
        <div class="row">
        <label>CSV option available. Format required as shown below:</label>
        </div>
        <div class="row">
        <table>
            <thead>
                <tr>
                    <th style="text-transform: none;">client_loginid</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td>CR12345</td>
                </tr>
                <tr>
                    <td>CR23456</td>
                </tr>
            </tbody>
        </table>
        </div>
        <div class="row">
        <label>Upload CSV (Max 1MB):</label>
            <input type="file" name="client_loginids_csv" onchange="checkCSV(event, 1048576)" accept=".csv" />
        </div>
        <input type="submit" class="btn btn--primary" value="Resync MT5 Accounts Jurisdiction Status">
    </form>~;

code_exit_BO();
