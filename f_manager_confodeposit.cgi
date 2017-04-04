#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Path::Tiny;
use Try::Tiny;
use Brands;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Database::DataMapper::Payment;
use BOM::Database::ClientDB;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Platform::AuditLog;
use BOM::ContractInfo;
use BOM::Backoffice::Config;
use BOM::Backoffice::Sysinit ();
use BOM::Platform::Runtime;
BOM::Backoffice::Sysinit::init();

PrintContentType();

print qq[<style>p {margin: 12px}</style>];

my $cgi    = CGI->new;
my %params = $cgi->Vars;

for (qw/account amount currency ttype range/) {
    next if $params{$_};
    print "ERROR: $_ cannot be empty. Please try again";
    code_exit_BO();
}

if (BOM::Platform::Runtime->instance->app_config->system->suspend->system) {
    print "ERROR: Sytem is suspended";
    code_exit_BO();
}

# Why all the delete-params?  Because any remaining form params just get passed directly
# to the new-style database payment-handlers.  There's no need to mention those in this module.

my $curr              = $params{currency};
my $loginID           = uc((delete $params{account} || ''));
my $toLoginID         = uc((delete $params{to_account} || ''));
my $amount            = delete $params{amount};
my $informclient      = delete $params{informclientbyemail};
my $ttype             = delete $params{ttype};
my $DCcode            = delete $params{DCcode};
my $range             = delete $params{range};
my $encoded_loginID   = encode_entities($loginID);
my $encoded_toLoginID = encode_entities($toLoginID);

BOM::Backoffice::Auth0::can_access(['Payments']);
my $staff = BOM::Backoffice::Auth0::from_cookie();
my $clerk = $staff->{nickname};

my $client = eval { Client::Account->new({loginid => $loginID}) } || do {
    print "Error: no such client $encoded_loginID";
    code_exit_BO();
};
my $broker = $client->broker;

my $toClient;
if ($ttype eq 'TRANSFER') {
    unless ($toLoginID) {
        print "ERROR: transfer-to LoginID missing";
        code_exit_BO();
    }
    $toClient = eval { Client::Account->new({loginid => $toLoginID}) } || do {
        print "Error: no such transfer-to client $encoded_toLoginID";
        code_exit_BO();
    };
    if ($broker ne $toClient->broker) {
        printf "ERROR: $toClient broker is %s not %s", encode_entities($toClient->broker), encode_entities($broker);
        code_exit_BO();
    }
}

for my $c ($client, $toClient) {
    $c || next;
    if ($client->get_status('disabled')) {
        print build_client_warning_message($loginID);
    }
    if (!$c->is_first_deposit_pending && $c->currency && $c->currency ne $curr) {
        printf "ERROR: Invalid currency [%s], default for [$c] is [%s]", encode_entities($curr), $c->currency;
        code_exit_BO();
    }
}

$amount =~ s/\,//g;

unless (looks_like_number($amount)) {
    print "ERROR: non-numeric amount: " . encode_entities($amount);
    code_exit_BO();
}

if ($amount < 0.001 || $amount > 200_000) {
    print "ERROR: amount $amount not in acceptable range .001-to-200,000";
    code_exit_BO();
}

my ($low, $high) = $range =~ /^(\d+)\-(\d+)$/;
if ($amount < $low || $amount > $high) {
    printf "ERROR: Transaction amount $amount is not in the range (%s)", encode_entities($range);
    code_exit_BO();
}
my $signed_amount = $amount;
$signed_amount *= -1 if $ttype eq 'DEBIT';

my $email      = $client->email;
my $salutation = $client->salutation;
my $first_name = $client->first_name;
my $last_name  = $client->last_name;

my $error = BOM::DualControl->new({
        staff           => $clerk,
        transactiontype => $ttype
    })->validate_payment_control_code($DCcode, $loginID, $curr, $amount);
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
    $payment_mapper->is_duplicate_manual_payment({
            remark => ($params{remark} || ''),
            date   => Date::Utility->new,
            amount => $signed_amount
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
        1;
    } || do {
        my $err = $@;
        print qq[<p style="color:#F00">$encoded_loginID Failed. $err</p>];
        code_exit_BO();
    };

    printf qq[<p style="color:#070">Done. %s will be ok.</p>], encode_entities($ttype);
    $params{skip_validation} = 1;
}

my $transRef;

my $client_db = BOM::Database::ClientDB->new({
    client_loginid => $loginID,
});

$client_db->freeze || do {
    print "ERROR: Account stuck in previous transaction $encoded_loginID";
    code_exit_BO();
};

my $to_client_db = do {
    BOM::Database::ClientDB->new({client_loginid => $toLoginID}) if $toLoginID;
};

if ($ttype eq 'TRANSFER') {
    $to_client_db->freeze || do {
        print "ERROR: To-Account stuck in previous transaction $encoded_toLoginID";
        code_exit_BO();
        }
}

# NEW PAYMENT HANDLERS ..

my ($leave, $client_pa_exp);
try {
    if ($ttype eq 'CREDIT' || $ttype eq 'DEBIT') {
        $client->smart_payment(
            %params,    # these are payment-type-specific params from the html form.
            amount => $signed_amount,
            staff  => $clerk,
        );
        $client_pa_exp = $client;
    } elsif ($ttype eq 'TRANSFER') {
        $client->payment_account_transfer(
            currency => $curr,
            toClient => $toClient,
            amount   => $amount,
            staff    => $clerk,
        );
        $client_pa_exp = $toClient;
    }
}
catch {
    print "<p>TRANSACTION ERROR: This payment violated a fundamental database rule.  Details:<br/>$_</p>";
    $leave = 1;
    printf STDERR "got here\n";
};

$client_db->unfreeze;
$to_client_db->unfreeze if $toLoginID;

code_exit_BO() if $leave;

my $today = Date::Utility->today;
if ($ttype eq 'CREDIT' and $params{payment_type} !~ /^(?:affiliate_reward|arbitrary_markup|free_gift)$/) {
    # we need to set paymentagent_expiration_date for manual deposit
    # check with compliance if you want to change this
    try {
        $client_pa_exp->payment_agent_withdrawal_expiration_date($today->date_yyyymmdd);
        $client_pa_exp->save;
    }
    catch {
        warn "Not able to set payment agent expiration date for " . $client_pa_exp->loginid;
    };
}

my $now = Date::Utility->new;
# Logging
my $msg = $now->datetime . " $ttype $curr$amount $loginID clerk=$clerk (DCcode=$DCcode) $ENV{REMOTE_ADDR}";
BOM::Platform::AuditLog::log($msg, $loginID, $clerk);
Path::Tiny::path(BOM::Backoffice::Config::config->{log}->{deposit})->append_utf8($msg);

# Print confirmation
Bar("$ttype confirmed");
my $success_message;
my $new_bal = $acc->load && $acc->balance;
if ($ttype eq 'TRANSFER') {
    my $toAcc = $toClient->default_account->load;
    my $toBal = $toAcc->balance;
    $success_message = qq[Transfer $curr$amount from $encoded_loginID to $encoded_toLoginID confirmed.<br/>
                        For $encoded_loginID new account balance is $curr$new_bal.<br/>
                        For $encoded_toLoginID new account balance is $curr$toBal.<br/>];
} else {
    $success_message = qq[$encoded_loginID $ttype $curr$amount confirmed.<br/>
                         New account balance is $curr$new_bal.<br/>];
}
print qq[<p class="success_message">$success_message</p>];

Bar("Today's entries for $encoded_loginID");

my $after  = $today->datetime_yyyymmdd_hhmmss;
my $before = $today->plus_time_interval('1d')->datetime_yyyymmdd_hhmmss;

my $statement = client_statement_for_backoffice({
    client => $client,
    before => $before,
    after  => $after
});

BOM::Backoffice::Request::template->process(
    'backoffice/account/statement.html.tt',
    {
        transactions            => $statement->{transactions},
        balance                 => $statement->{balance},
        currency                => $client->currency,
        loginid                 => $client->loginid,
        depositswithdrawalsonly => request()->param('depositswithdrawalsonly'),
        contract_details        => \&BOM::ContractInfo::get_info,
    },
) || die BOM::Backoffice::Request::template->error();

#View updated statement
print "<form action=\"" . request()->url_for("backoffice/f_manager_history.cgi") . "\" method=\"post\">";
print "<input type=hidden name=loginID value='$encoded_loginID'>";
print "<input type=hidden name=\"broker\" value=\"" . encode_entities($broker) . '">';
print "<input type=hidden name=\"l\" value=\"EN\">";
print "VIEW CLIENT UPDATED STATEMENT: <input type=\"submit\" value=\"View $encoded_loginID updated statement for Today\">";
print "</form>";

# Email staff who input payment
my $staffemail = $staff->{'email'};

my $brand            = Brands->new(name => request()->brand);
my $email_accountant = $brand->emails('accounting');
my $toemail          = ($staffemail eq $email_accountant) ? "$staffemail" : "$staffemail,$email_accountant";

if ($toemail && $informclient) {

    my $subject = $ttype eq 'CREDIT' ? localize('Deposit') : localize('Withdrawal');
    my $who = BOM::Platform::Locale::translate_salutation($salutation) . " $first_name $last_name";
    my $email_body =
          localize('Dear')
        . " $who,\n\n"
        . localize('We would like to inform you that your [_1] has been processed.', $subject) . "\n\n"
        . localize('Kind Regards') . "\n\n"
        . 'Binary.com';

    my $support_email = $brand->emails('support');

    my $result = send_email({
        from                  => $support_email,
        to                    => $email,
        subject               => $subject,
        message               => [$email_body],
        use_email_template    => 1,
        template_loginid      => $loginID,
        email_content_is_html => 1,
    });

    $client->add_note($subject, $email_body);
}

code_exit_BO();

