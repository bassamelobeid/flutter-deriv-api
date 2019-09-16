#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Path::Tiny;
use Try::Tiny;
use HTML::Entities;
use Scope::Guard;

use LandingCompany::Registry;

use f_brokerincludeall;
use BOM::Database::DataMapper::Payment;
use BOM::Database::ClientDB;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::User::AuditLog;
use BOM::ContractInfo;
use BOM::Backoffice::Config;
use BOM::Backoffice::Sysinit ();
use BOM::Config::Runtime;
use BOM::Platform::Event::Emitter;
BOM::Backoffice::Sysinit::init();

PrintContentType();

=head2 _incr_misc_checks

Function to handle external client transactions, that are related to different
compliance checks. This only applies for bank wire transfers and doughflow (external
cashier).

=cut

sub _incr_misc_checks {
    my ($args) = @_;

    my $client      = $args->{client};
    my $amount      = $args->{amount};
    my $transaction = $args->{transfer_type} eq 'CREDIT' ? 'deposit' : 'withdrawal';

    $client->increment_social_responsibility_values({
            deposit_amount => $amount,
            deposit_count  => 1
        })
        if ($client->landing_company->social_responsibility_check_required
        && $transaction eq 'deposit');

    $client->increment_qualifying_payments({
            action => $transaction,
            amount => abs($amount)}) if $client->landing_company->qualifying_payment_check_required;

    return undef;
}

print qq[<style>p {margin: 12px}</style>];

my %params = %{request()->params};

for (qw/account amount currency ttype range/) {
    next if $params{$_};
    print "ERROR: $_ cannot be empty. Please try again";
    code_exit_BO();
}

if (BOM::Config::Runtime->instance->app_config->system->suspend->payments) {
    print "ERROR: Payments are suspended";
    code_exit_BO();
}

# Why all the delete-params?  Because any remaining form params just get passed directly
# to the new-style database payment-handlers.  There's no need to mention those in this module.
my $loginID   = uc((delete $params{account}    || ''));
my $toLoginID = uc((delete $params{to_account} || ''));
my $informclient     = delete $params{informclientbyemail};
my $ttype            = delete $params{ttype};
my $DCcode           = delete $params{DCcode};
my $range            = delete $params{range};
my $transaction_date = delete $params{date_received};
my $reference_id     = delete $params{reference_id};

my $curr         = $params{currency};
my $amount       = $params{amount};
my $payment_type = $params{payment_type};
my $remark       = $params{remark};

my $encoded_loginID   = encode_entities($loginID);
my $encoded_toLoginID = encode_entities($toLoginID);

my $is_internal_payment = any { $payment_type eq $_ } qw( bank_money_transfer external_cashier );

my $clerk = BOM::Backoffice::Auth0::get_staffname();

unless ($curr =~ /^[A-Z]{3}$/ && LandingCompany::Registry::get_currency_type($curr)) {
    print "Invalid currency, please check: " . encode_entities($curr);
    code_exit_BO();
}
my $client = eval { BOM::User::Client->new({loginid => $loginID}) } || do {
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
    $toClient = eval { BOM::User::Client->new({loginid => $toLoginID}) } || do {
        print "Error: no such transfer-to client $encoded_toLoginID";
        code_exit_BO();
    };
    if ($broker ne $toClient->broker) {
        printf "ERROR: $toClient broker is %s not %s", encode_entities($toClient->broker), encode_entities($broker);
        code_exit_BO();
    }
}

if ($client->is_same_user_as($toClient)) {
    print "ERROR: you cannot perform internal transfer between accounts under the same user!";
    code_exit_BO();
}

for my $c ($client, $toClient) {
    $c || next;
    if ($client->status->disabled) {
        print build_client_warning_message($loginID);
    }
    if ($c->currency && $c->currency ne $curr) {
        printf "ERROR: Invalid currency [%s], client id: [%s] currency is [%s].You cannot have transfer to a client with different currency!",
            encode_entities($curr), $c->loginid, $c->currency;
        code_exit_BO();
    }
}

$amount =~ s/\,//g;

unless (looks_like_number($amount)) {
    print "ERROR: non-numeric amount: " . encode_entities($amount);
    code_exit_BO();
}

if ($amount < 0.00000001 || $amount > 200_000) {
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

unless ($client->landing_company->is_currency_legal($curr)) {
    printf "ERROR: Currency %s is not legal for this client's landing company", encode_entities($curr);
    code_exit_BO();
}

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
            remark => ($remark || ''),
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

    if ($ttype eq 'CREDIT') {
        if (my @dup_account =
            BOM::Database::ClientDB->new({broker_code => $cli->broker_code})
            ->get_duplicate_client({(map { $_ => $cli->$_ } qw( first_name last_name email date_of_birth phone ))}))
        {
            print qq( <p style="color:#F00">Duplicated Account suspected: ${dup_account[0]} (${dup_account[4]})</p> );
            code_exit_BO();
        }
    }

    printf qq[<p style="color:#070">Done. %s will be ok.</p>], encode_entities($ttype);
    $params{skip_validation} = 1;
}

my $transRef;

my $client_db = BOM::Database::ClientDB->new({
    client_loginid => $loginID,
});

unless ($client_db) {
    print "ERROR: ClientDB for loginid $encoded_loginID could not be initialized";
    code_exit_BO();
}

my $guard_scope = Scope::Guard::guard {
    $client_db->unfreeze;
};

unless ($client_db->freeze) {
    print "ERROR: Account stuck in previous transaction $encoded_loginID";
    code_exit_BO();
}

my ($guard_scope_to, $to_client_db);
if ($ttype eq 'TRANSFER') {
    $to_client_db = do {
        BOM::Database::ClientDB->new({client_loginid => $toLoginID});
    };

    unless ($to_client_db) {
        print "ERROR: ClientDB for to_loginid $encoded_loginID could not be initialized";
        code_exit_BO();
    }

    $guard_scope_to = Scope::Guard::guard {
        $to_client_db->unfreeze;
    };

    unless ($to_client_db->freeze) {
        print "ERROR: To-Account stuck in previous transaction $encoded_toLoginID";
        code_exit_BO();
    }
}

# NEW PAYMENT HANDLERS ..

my ($leave, $client_pa_exp);
try {
    my $fdp = $client->is_first_deposit_pending;

    if ($payment_type eq 'external_cashier') {
        code_exit_BO("Remarks is mandatory for doughflow payments.") unless $remark;
        if ($ttype eq 'CREDIT') {
            # check if its withdrawal reversal
            # transaction_id is not required in that case
            if ($remark =~ 'DoughFlow withdrawal_reversal') {
                delete $params{transaction_id};
            } else {
                code_exit_BO("Transaction id is mandatory for doughflow credit.") if not $params{transaction_id};
                code_exit_BO(
                    "Transaction id provided does not match with one provided in remark (it should be in format like: transaction_id=33232).")
                    if $remark !~ /transaction_id=$params{transaction_id}/;
            }
        }
    }

    if ($ttype eq 'CREDIT' || $ttype eq 'DEBIT') {
        $client->smart_payment(
            %params,    # these are payment-type-specific params from the html form.
            amount => $signed_amount,
            staff  => $clerk,
        );

        BOM::Platform::Event::Emitter::emit(
            'payment_deposit',
            {
                loginid          => $client->loginid,
                is_first_deposit => $fdp
            }) if $ttype eq 'CREDIT';

        # Handle deposits for doughflow and bank money transfers (internal)
        # Exclude reversal transactions
        _incr_misc_checks({
                client        => $client,
                amount        => $signed_amount,
                transfer_type => $ttype
            }) if $is_internal_payment && $remark !~ /reversal/;

        $client_pa_exp = $client;
    } elsif ($ttype eq 'TRANSFER') {
        $client->payment_account_transfer(
            currency     => $curr,
            toClient     => $toClient,
            amount       => $amount,
            staff        => $clerk,
            fees         => 0,
            gateway_code => 'account_transfer',
        );
        $client_pa_exp = $toClient;
    }
}
catch {
    print "<p>TRANSACTION ERROR: This payment violated a fundamental database rule.  Details:<br/>$_</p>";
    $leave = 1;
    printf STDERR "Error: $_\n";
};

code_exit_BO() if $leave;
my $today = Date::Utility->today;
if ($ttype eq 'CREDIT' and $is_internal_payment) {
    # unset pa_withdrawal_explicitly_allowed for bank_wire and doughflow mannual deposit
    try {
        $client->status->clear_pa_withdrawal_explicitly_allowed;
    }
    catch {
        warn "Not able to unset payment agent explicity allowed flag for " . $client_pa_exp->loginid;
    };
}
my $now = Date::Utility->new;
# Logging
my $msg = $now->datetime . " $ttype $curr$amount $loginID clerk=$clerk (DCcode=$DCcode) $ENV{REMOTE_ADDR}";
BOM::User::AuditLog::log($msg, $loginID, $clerk);
Path::Tiny::path(BOM::Backoffice::Config::config()->{log}->{deposit})->append_utf8($msg);

# Print confirmation
Bar("$ttype confirmed");
my $success_message;
my $new_bal = $acc->balance;
if ($ttype eq 'TRANSFER') {
    my $toAcc = $toClient->default_account;
    my $toBal = $toAcc->balance;
    $success_message = qq[Transfer $curr$amount from $encoded_loginID to $encoded_toLoginID confirmed.<br/>
                        For $encoded_loginID new account balance is $curr$new_bal.<br/>
                        For $encoded_toLoginID new account balance is $curr$toBal.<br/>];
} else {
    $success_message = qq[$encoded_loginID $ttype $curr$amount confirmed.<br/>
                         New account balance is $curr$new_bal.<br/>];
}
print qq[<p class="success_message">$success_message</p>];

Bar("Today's entries for $loginID");

my $after  = $today->datetime_yyyymmdd_hhmmss;
my $before = $today->plus_time_interval('1d')->datetime_yyyymmdd_hhmmss;

my $statement = client_statement_for_backoffice({
    client => $client,
    before => $before,
    after  => $after
});

BOM::Backoffice::Request::template()->process(
    'backoffice/account/statement.html.tt',
    {
        transactions            => $statement->{transactions},
        balance                 => $statement->{balance},
        currency                => $client->currency,
        loginid                 => $client->loginid,
        depositswithdrawalsonly => request()->param('depositswithdrawalsonly'),
        contract_details        => \&BOM::ContractInfo::get_info,
    },
) || die BOM::Backoffice::Request::template()->error();

#View updated statement
print "<form action=\"" . request()->url_for("backoffice/f_manager_history.cgi") . "\" method=\"post\">";
print "<input type=hidden name=loginID value='$encoded_loginID'>";
print "<input type=hidden name=\"broker\" value=\"" . encode_entities($broker) . '">';
print "<input type=hidden name=\"l\" value=\"EN\">";
print "VIEW CLIENT UPDATED STATEMENT: <input type=\"submit\" value=\"View $encoded_loginID updated statement for Today\">";
print "</form>";

if ($informclient) {
    my $subject = $ttype eq 'CREDIT' ? localize('Deposit') : localize('Withdrawal');

    my $email_body =
          localize('Dear [_1] [_2] [_3],', BOM::Platform::Locale::translate_salutation($salutation), $first_name, $last_name) . "\n\n"
        . localize('We would like to inform you that your [_1] has been processed.', $subject) . "\n\n"
        . localize('Kind Regards') . "\n\n"
        . (ucfirst BOM::Config::domain()->{default_domain});

    try {
        send_email({
            from                  => request()->brand->emails('support'),
            to                    => $client->email,
            subject               => $subject,
            message               => [$email_body],
            use_email_template    => 1,
            template_loginid      => $loginID,
            email_content_is_html => 1,
        });
    }
    catch {
        code_exit_BO("Transaction was performed, please check client statement but an error occured while sending email. Error details $_");
    };
}

code_exit_BO();

