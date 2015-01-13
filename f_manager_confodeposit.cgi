#!/usr/bin/perl
package main;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Path::Tiny;
use File::ReadBackwards;

use f_brokerincludeall;
use BOM::Platform::Data::Persistence::DataMapper::Payment;
use BOM::Platform::Email qw(send_email);
use BOM::View::Language;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Context;
use BOM::View::Controller::Bet;
use BOM::View::Cashier;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

my $cgi    = new CGI;
my %params = $cgi->Vars;

for (qw/account amount currency ttype range/) {
    next if $params{$_};
    print "ERROR: $_ cannot be empty. Please try again";
    code_exit_BO();
}

# Why all the delete-params?  Because any remaining form params just get passed directly
# to the new-style database payment-handlers.  There's no need to mention those in this module.

my $loginID   = uc((delete $params{account}    || ''));
my $toLoginID = uc((delete $params{to_account} || ''));
my $curr      = delete $params{currency};
my $amount    = delete $params{amount};
my $informclient   = delete $params{informclientbyemail};
my $ttype          = delete $params{ttype};
my $ajax_only      = delete $params{ajax_only};
my $DCstaff        = delete $params{DCstaff};
my $DCcode         = delete $params{DCcode};
my $range          = delete $params{range};
my $overridelimits = delete $params{overridelimits};

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

# Check Dual Control Code

# We can do development tests without hassling with DCCs.. but to test DCCs on dev, make the amount as below.
if (!BOM::Platform::Runtime->instance->app_config->system->on_development || $amount == 1234.56) {

    if (!$DCstaff) {
        print "ERROR: fellow staff name for dual control code not specified";
        code_exit_BO();
    }

    if (!$DCcode) {
        print "ERROR: dual control code not specified";
        code_exit_BO();
    }

    if ($DCstaff eq $clerk) {
        print "ERROR: fellow staff name for dual control code cannot be yourself!";
        code_exit_BO();
    }

    my $validcode = DualControlCode($DCstaff, $token, $curr, $amount, BOM::Utility::Date->new->date_ddmmmyy, $ttype, $loginID);

    if (substr(uc($DCcode), 0, 5) ne substr(uc($validcode), 0, 5)) {
        print "ERROR: Dual Control Code $DCcode is invalid (code FMDO). Check the fellow staff name, amount, date and transaction type.";
        code_exit_BO();
    }

    #check if control code already used
    my $count    = 0;
    my $log_file = File::ReadBackwards->new("/var/log/fixedodds/fmanagerconfodeposit.log");
    while ((defined(my $l = $log_file->readline)) and ($count++ < 200)) {
        if ($l =~ /DCcode\=$DCcode/i) {
            print "ERROR: this control code has already been used today!";
            code_exit_BO();
        }
    }

    if (not ValidDualControlCode($DCcode)) {
        print "ERROR: invalid dual control code!";
        code_exit_BO();
    }
}

my $acc = $client->set_default_account($curr);    # creates a first account if necessary.
my $bal = $acc->balance;

if (($ttype =~ /TRANSFER|DEBIT/) and ($bal < $amount)) {
    print "ERROR: Client balance is only $curr$bal - can't withdraw $curr$amount";
    code_exit_BO();
}

# Check Staff Authorisation Limit ##################
my $staffauthlimit = get_staff_payment_limit($clerk);
if ($amount > $staffauthlimit) {
    print "ERROR: The amount ($amount) is larger than authorization limit for $clerk ($staffauthlimit)";
    code_exit_BO();
}

# Check didn't hit Reload
my $payment_mapper = BOM::Platform::Data::Persistence::DataMapper::Payment->new({
    'client_loginid' => $loginID,
    'currency_code'  => $curr,
});

if (
    $payment_mapper->is_duplicate_payment({
            remark => ($params{remark} || ''),
            date   => BOM::Utility::Date->new,
            amount => $signed_amount,
        }))
{
    print "ERROR: did you hit Reload ?  Very similar line already appears on client statement";
    code_exit_BO();
}

# Check client withdrawal limits
if (!$overridelimits) {
    if ($ttype =~ /DEBIT|TRANSFER/) {
        Bar('Performing client-side withdrawal limit checks');

        print '<p>Performing client-side withdrawal limit checks...</p>'
            . '<p style="font-style:italic;">Note: the system is now simulating a client-side withdrawal and checking if it gets blocked by the client-side withdrawal limits. You can over-ride this by clicking on the over-ride checkbox on the previous page.</p>'
            . '<p>If the client-side withdrawal check fails, then the withdrawal will not have been processed.</p>';

        print '<p style="color:red;">';

        my $withdrawal_limits = $client->get_withdrawal_limits();
        BOM::View::Cashier::check_if_client_can_withdraw({
            client            => $client,
            amount            => $amount,
            withdrawal_limits => $withdrawal_limits,
        });
        print '</p>';

        print '<p><b>Done.</b> The withdrawal is allowed.</p>';
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

if ($ttype eq 'CREDIT' || $ttype eq 'DEBIT') {

    $client->smart_payment(
        %params,    # these are payment-type-specific params from the html form.
        currency        => $curr,
        amount          => $signed_amount,
        staff           => $clerk,
        skip_validation => 1,
    );

} elsif ($ttype eq 'TRANSFER') {

    $client->payment_account_transfer(
        currency => $curr,
        toClient => $toClient,
        amount   => $amount,
        staff    => $clerk,
        )

}

BOM::Platform::Transaction->unfreeze_client($loginID);
BOM::Platform::Transaction->unfreeze_client($toLoginID) if $toLoginID;

my $now = BOM::Utility::Date->new;
# Logging
Path::Tiny::path("/var/log/fixedodds/fmanagerconfodeposit.log")
    ->append($now->datetime . " $ttype $curr$amount $loginID clerk=$clerk fellow=$DCstaff DCcode=$DCcode $ENV{REMOTE_ADDR}");

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

my $today  = BOM::Utility::Date->today;
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

    my $subject = $ttype eq 'CREDIT' ? localize('Deposit via Bank Wire') : localize('Withdrawal via Bank Wire');
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
    });

    $client->add_note($subject, $email_body);
}

code_exit_BO();

