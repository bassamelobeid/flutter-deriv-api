#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use HTML::Entities           qw(encode_entities);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Request qw(request);
use BOM::Platform::Event::Emitter;
use BOM::DualControl;
use BOM::MT5::BOUtility;
use Log::Any        qw($log);
use List::MoreUtils qw(uniq);

BOM::Backoffice::Sysinit::init();

my %params    = %{request()->params};
my $input_str = delete $params{mt5_accounts};
$input_str =~ s/\s+//g;
my @mt5_accounts    = split(',', uc($input_str || ''));
my $DCcode          = delete $params{DCcode};
my $override_status = delete $params{skip_validation};
my $staff           = BOM::Backoffice::Auth0::get_staffname();

unless (@mt5_accounts) {
    print 'No MT5 Accounts Found! <br>';
    code_exit_BO();
}

@mt5_accounts = uniq(@mt5_accounts);
my @invalid_mt5 = @{BOM::MT5::BOUtility::valid_mt5_check(\@mt5_accounts)};

if (@invalid_mt5) {
    print 'Submission Halted: Incorrect MT5 Account Detected <br>' . join('', @invalid_mt5);
    code_exit_BO();
}

#Code generated from batch_payment_control_code
my $error = BOM::DualControl->new({
        staff           => $staff,
        transactiontype => 'TRANSFER',
    })->validate_batch_account_transfer_control_code($DCcode, \@mt5_accounts);

if ($error) {
    print encode_entities($error->get_mesg());
    code_exit_BO();
}

BOM::Platform::Event::Emitter::emit(
    'mt5_deriv_auto_rescind',
    {
        mt5_accounts    => \@mt5_accounts,
        override_status => $override_status
    });

print join(', ', @mt5_accounts) . ' Auto Rescind/Transfer Request Initiated.';
code_exit_BO();
