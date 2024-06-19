#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
use BOM::User::WalletMigration;
use List::Util qw(none);
use Syntax::Keyword::Try;

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation('Wallet Migration');

my %input = request()->params->%*;
my %output;
my $migration;
my $loginid = $input{loginID};

if ((my $action = $input{action})) {
    try {
        my $client = BOM::User::Client->get_client_instance($loginid) // die "Invalid loginid\n";

        $migration = BOM::User::WalletMigration->new(
            user   => $client->user,
            app_id => 4,
        );

        if ($action eq 'migrate') {
            $migration->start;
            $output{message} = "Migration started for $loginid";
        } elsif ($action eq 'reset') {
            $migration->reset;
            $output{message} = "Migration reset for $loginid";
        } elsif ($action eq 'force_migrate') {
            $migration->start(force => 1);
            $output{message} = "Migration started for $loginid";
        }
    } catch ($e) {
        $output{error} = ref $e eq 'HASH' ? $e->{error_code} // 'unknown error' : $e;
    }
}

if ($loginid) {
    try {
        my $client = BOM::User::Client->get_client_instance($loginid) // die "Invalid loginid\n";

        $migration //= BOM::User::WalletMigration->new(
            user   => $client->user,
            app_id => 4,
        );

        $output{loginid} = $loginid;
        $output{state}   = $migration->state(no_cache => 1);

        if ($output{state} eq 'eligible') {
            $output{action} = 'migrate';
        } elsif ($output{state} eq 'failed') {
            $output{action} = 'reset';
        } elsif ($output{state} eq 'ineligible') {
            $output{eligibility_checks} = [$migration->eligibility_checks(no_cache => 1)];
            # we will allow force migration unless there are specific reasons for ineligibility
            $output{action} = 'force_migrate'
                if none { $_ =~ /^(unsupported_country|registered_p2p|registered_pa|no_svg_usd_account)$/ } $output{eligibility_checks}->@*;
        }
    } catch ($e) {
        $output{error} = ref $e eq 'HASH' ? $e->{error_code} // 'unknown error' : $e;
    }
}

BOM::Backoffice::Request::template()->process('backoffice/wallet_migration.tt', \%output);

code_exit_BO();
