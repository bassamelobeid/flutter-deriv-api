#!/usr/bin/perl
package main;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Path::Tiny;
use Try::Tiny;

use f_brokerincludeall;
use BOM::Database::DataMapper::Payment;
use BOM::Platform::Email qw(send_email);
use BOM::View::Language;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Context;
use BOM::View::Controller::Bet;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

print qq[<style>p {margin: 12px}</style>];

my $cgi    = new CGI;
my %params = $cgi->Vars;

for (qw/account amount currency ttype range/) {
    next if $params{$_};
    print "ERROR: $_ cannot be empty. Please try again";
    code_exit_BO();
}

# Why all the delete-params?  Because any remaining form params just get passed directly
# to the new-style database payment-handlers.  There's no need to mention those in this module.

my $curr         = $params{currency};
my $loginID      = uc((delete $params{account} || ''));
my $toLoginID    = uc((delete $params{to_account} || ''));
my $amount       = delete $params{amount};
my $informclient = delete $params{informclientbyemail};
my $ttype        = delete $params{ttype};
my $ajax_only    = delete $params{ajax_only};
my $DCcode       = delete $params{DCcode};
my $range        = delete $params{range};

BOM::Platform::Auth0::can_access(['Payments']);
my $token = BOM::Platform::Context::request()->bo_cookie->token;
my $staff = BOM::Platform::Auth0::from_cookie();
my $clerk = $staff->{nickname};

my $client = eval { BOM::Platform::Client->new({loginid => $loginID}) } || do {
    print "Error: no such client $loginID";
    code_exit_BO();
};
my $broker = $client->broker;

my $toClient;
if ($ttype eq 'TRANSFER') {
    unless ($toLoginID) {
        print "ERROR: transfer-to LoginID missing";
        code_exit_BO();
    }
    $toClient = eval { BOM::Platform::Client->new({loginid => $toLoginID}) } || do {
        print "Error: no such transfer-to client $toLoginID";
        code_exit_BO();
    };
    if ($broker ne $toClient->broker) {
        printf "ERROR: $toClient broker is %s not %s", $toClient->broker, $broker;
        code_exit_BO();
    }
}

for my $c ($client, $toClient) {
    $c || next;
    if ($client->get_status('disabled')) {
        print build_client_warning_message($loginID);
    }
    if (!$c->is_first_deposit_pending && $c->currency && $c->currency ne $curr) {
        printf "ERROR: Invalid currency [$curr], default for [$c] is [%s]", $c->currency;
        code_exit_BO();
    }
}

$amount =~ s/\,//g;

unless (looks_like_number($amount)) {
    print "ERROR: non-numeric amount: $amount";
    code_exit_BO();
}

if ($amount < 0.001 || $amount > 200_000) {
    print "ERROR: amount $amount not in acceptable range .001-to-200,000";
    code_exit_BO();
}

my ($low, $high) = $range =~ /^(\d+)\-(\d+)$/;
if ($amount < $low || $amount > $high) {
    print "ERROR: Transaction amount $amount is not in the range ($range)";
    code_exit_BO();
}
my $signed_amount = $amount;
$signed_amount *= -1 if $ttype eq 'DEBIT';

my $email      = $client->email;
my $salutation = $client->salutation;
my $first_name = $client->first_name;
my $last_name  = $client->last_name;

my $error = BOM::DualControl->new({staff => $clerk, transactiontype => $ttype})->validate_payment_control_code($DCcode, $loginID, $curr, $amount);
if ($error) {
    print $error->get_mesg();
    code_exit_BO();
}

my $acc = $client->set_default_account($curr);    # creates a first account if necessary.

# Check didn't hit Reload
my $payment_mapper = BOM::Database::DataMapper::Payment->new({
    'client_loginid' => $loginID,
    'currency_code'  => $curr,
});

if (
    $payment_mapper->is_duplicate_payment({
            remark => ($params{remark} || ''),
            date   => Date::Utility->new,
            amount => $signed_amount,
        }))
{
    print "ERROR: did you hit Reload ?  Very similar line already appears on client statement";
    code_exit_BO();
}

# validate payment (both sides if a transfer)
unless ($params{skip_validation}) {
    Bar('Checking payment validation rules');

    print qq[<p><em>You can override this with "Override Status Checks"</em></p>];

    my $cli = $client;
    eval {
        if ($ttype eq 'TRANSFER') {
            $cli->validate_payment(%params, amount => -$amount);
            $cli = $toClient;
            $cli->validate_payment(%params, amount => $amount);
        } else {
            $cli->validate_payment(%params, amount => $signed_amount);
        }
    };
    if (my $err = $@) {
        print qq[<p style="color:#F00">$cli Failed. $err</p>];
        code_exit_BO();
    } else {
        print qq[<p style="color:#070">Done. $ttype will be ok.</p>];
        $params{skip_validation} = 1;
    }
}

my $transRef;

BOM::Platform::Transaction->freeze_client($loginID) || do {
    print "ERROR: Account stuck in previous transaction $loginID";
    code_exit_BO();
};

if ($ttype eq 'TRANSFER') {
    BOM::Platform::Transaction->freeze_client($toLoginID) || do {
        print "ERROR: To-Account stuck in previous transaction $toLoginID";
        code_exit_BO();
        }
}

# NEW PAYMENT HANDLERS ..

my $leave;
try {
    if ($ttype eq 'CREDIT' || $ttype eq 'DEBIT') {
        $client->smart_payment(
            %params,    # these are payment-type-specific params from the html form.
            amount => $signed_amount,
            staff  => $clerk,
        );

    } elsif ($ttype eq 'TRANSFER') {
        $client->payment_account_transfer(
            currency => $curr,
            toClient => $toClient,
            amount   => $amount,
            staff    => $clerk,
        );
    }
}
catch {
    print "<p>TRANSACTION ERROR: This payment violated a fundamental database rule.  Details:<br/>$_</p>";
    $leave = 1;
    printf STDERR "got here\n";
};

BOM::Platform::Transaction->unfreeze_client($loginID);
BOM::Platform::Transaction->unfreeze_client($toLoginID) if $toLoginID;

code_exit_BO() if $leave;

my $now = Date::Utility->new;
# Logging
Path::Tiny::path("/var/log/fixedodds/fmanagerconfodeposit.log")
    ->append($now->datetime . " $ttype $curr$amount $loginID clerk=$clerk DCcode=$DCcode $ENV{REMOTE_ADDR}");

# Print confirmation
Bar("$ttype confirmed");
my $success_message;
my $new_bal = $acc->load && $acc->balance;
if ($ttype eq 'TRANSFER') {
    my $toAcc = $toClient->default_account->load;
    my $toBal = $toAcc->balance;
    $success_message = qq[Transfer $curr$amount from $client to $toClient confirmed.<br/>
                        For $client new account balance is $curr$new_bal.<br/>
                        For $toClient new account balance is $curr$toBal.<br/>];
} else {
    $success_message = qq[$client $ttype $curr$amount confirmed.<br/>
                         New account balance is $curr$new_bal.<br/>];
}
print qq[<p class="success_message">$success_message</p>];

Bar("Today's entries for $loginID");

my $today  = Date::Utility->today;
my $after  = $today->datetime_yyyymmdd_hhmmss;
my $before = $today->plus_time_interval('1d')->datetime_yyyymmdd_hhmmss;

my $statement = client_statement_for_backoffice({
    client => $client,
    before => $before,
    after  => $after
});

BOM::Platform::Context::template->process(
    'backoffice/account/statement.html.tt',
    {
        transactions            => $statement->{transactions},
        balance                 => $statement->{balance},
        currency                => $client->currency,
        loginid                 => $client->loginid,
        depositswithdrawalsonly => request()->param('depositswithdrawalsonly'),
        contract_details        => \&BOM::View::Controller::Bet::get_info,
    },
) || die BOM::Platform::Context::template->error();

#View updated statement
print "<form action=\"" . request()->url_for("backoffice/f_manager_history.cgi") . "\" method=\"post\">";
print "<input type=hidden name=loginID value='$loginID'>";
print "<input type=hidden name=\"broker\" value=\"$broker\">";
print "<input type=hidden name=\"l\" value=\"EN\">";
print "VIEW CLIENT UPDATED STATEMENT: <input type=\"submit\" value=\"View $loginID updated statement for Today\">";
print "</form>";

# Email staff who input payment
my $staffemail = $staff->{'email'};

my $email_accountant = BOM::Platform::Runtime->instance->app_config->accounting->email;
my $toemail          = ($staffemail eq $email_accountant) ? "$staffemail" : "$staffemail,$email_accountant";
my $website          = BOM::Platform::Runtime->instance->website_list->get_by_broker_code($broker);

if ($toemail && $informclient) {

    my $subject = $ttype eq 'CREDIT' ? localize('Deposit') : localize('Withdrawal');
    my $who = BOM::View::Language::translate_salutation($salutation) . " $first_name $last_name";
    my $email_body =
          localize('Dear')
        . " $who,\n\n"
        . localize('We would like to inform you that your [_1] has been processed.', $subject) . "\n\n"
        . localize('Kind Regards') . "\n\n"
        . $website->display_name;

    my $support_email = BOM::Platform::Context::request()->website->config->get('customer_support.email');

    my $result = send_email({
        from               => $support_email,
        to                 => $email,
        subject            => $website->display_name . ': ' . $subject,
        message            => [$email_body],
        use_email_template => 1,
        template_loginid   => $loginID,
    });

    $client->add_note($subject, $email_body);
}

code_exit_BO();

