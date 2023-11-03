#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Path::Tiny;
use Syntax::Keyword::Try;
use HTML::Entities;
use Log::Any qw($log);
use LandingCompany::Registry;

use f_brokerincludeall;
use BOM::Database::DataMapper::Payment;
use BOM::Database::ClientDB;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Locale;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::User::AuditLog;
use BOM::ContractInfo;
use BOM::Backoffice::Config;
use BOM::Backoffice::Sysinit ();
use BOM::Config::Runtime;
use BOM::Platform::Event::Emitter;
use BOM::Rules::Engine;
use Log::Any qw($log);

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

    $client->increment_social_responsibility_values({net_deposits => $amount})
        if ($client->landing_company->social_responsibility_check eq 'required'
        && $transaction eq 'deposit');

    $client->increment_social_responsibility_values({net_deposits => $amount})
        if ($client->landing_company->social_responsibility_check eq 'required'
        && $transaction eq 'withdrawal');

    $client->increment_qualifying_payments({
            action => $transaction,
            amount => abs($amount)}) if $client->landing_company->qualifying_payment_check_required;

    return undef;
}

my %params = %{request()->params};

for (qw/account amount currency ttype range/) {
    next if $params{$_};
    code_exit_BO("ERROR: $_ cannot be empty. Please try again.");
}

if (BOM::Config::Runtime->instance->app_config->system->suspend->payments) {
    code_exit_BO('ERROR: Payments are suspended');
}

# Why all the delete-params?  Because any remaining form params just get passed directly
# to the new-style database payment-handlers.  There's no need to mention those in this module.
my $loginID   = uc((delete $params{account}    || ''));
my $toLoginID = uc((delete $params{to_account} || ''));
# Don't be confused with the C<$notifyclient>.
# C<$informclient> is only set when the type is the cash transfer or bank transfer
# Whilst the C<$notifyclient> PP is only set when it is doughflow
my $informclient     = delete $params{informclientbyemail};
my $notifyclient     = delete $params{notify_client};
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

my $clerk = BOM::Backoffice::Auth::get_staffname();

unless ($curr =~ /^[a-zA-Z0-9]{2,20}$/ && LandingCompany::Registry::get_currency_type($curr)) {
    code_exit_BO('Invalid currency, please check: ' . encode_entities($curr));
}
my $client;
try {
    $client = BOM::User::Client->new({loginid => $loginID});
} catch ($e) {
    $log->warnf("Error when get client of login id $loginID. more detail: %s", $e);
};

code_exit_BO("Error: no such client $encoded_loginID") unless $client;

my $broker = $client->broker;

my $toClient;
if ($ttype eq 'TRANSFER') {
    unless ($toLoginID) {
        code_exit_BO('ERROR: transfer-to LoginID missing.');
    }
    try {
        $toClient = BOM::User::Client->new({loginid => $toLoginID});
    } catch ($e) {
        $log->warnf("Error when get client of login id $toLoginID. more detail: %s", $e);
    };

    code_exit_BO("Error: no such transfer-to client $encoded_toLoginID") unless $toClient;

    if ($broker ne $toClient->broker) {
        code_exit_BO(sprintf("ERROR: $toClient broker is %s not %s", encode_entities($toClient->broker), encode_entities($broker)));
    }
}

if ($client->is_same_user_as($toClient)) {
    code_exit_BO('ERROR: you cannot perform internal transfer between accounts under the same user!');
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
    try {
        if ($ttype eq 'TRANSFER') {
            my $rule_engine = BOM::Rules::Engine->new(client => [$client, $toClient]);
            $cli->validate_payment(
                %params,
                amount      => -$amount,
                rule_engine => $rule_engine
            );
            $cli = $toClient;
            $cli->validate_payment(
                %params,
                amount      => $amount,
                rule_engine => $rule_engine
            );
        } else {
            my $rule_engine = BOM::Rules::Engine->new(client => [$client]);
            $cli->validate_payment(
                %params,
                amount      => $signed_amount,
                rule_engine => $rule_engine
            );
        }
        1;
    } catch ($err) {
        print "<p class=\"error\">$encoded_loginID Failed. $err->{message_to_client}</p>";
        code_exit_BO();
    };

    if ($ttype eq 'CREDIT') {
        if (my @dup_account =
            BOM::Database::ClientDB->new({broker_code => $cli->broker_code})
            ->get_duplicate_client({(map { $_ => $cli->$_ } qw( first_name last_name email date_of_birth phone ))}))
        {
            print qq( <p class="error">Duplicated Account suspected: ${dup_account[0]} (${dup_account[4]})</p> );
            code_exit_BO();
        }
    }

    printf qq[<p class="success">Done. %s will be ok.</p>], encode_entities($ttype);
    $params{skip_validation} = 1;
}

# NEW PAYMENT HANDLERS ..

my ($client_pa_exp);
try {
    my $fdp = $client->is_first_deposit_pending;

    if ($payment_type eq 'external_cashier') {

        if ($ttype eq 'CREDIT') {
            if (not $params{transaction_id}) {
                code_exit_BO('Transaction id is mandatory for doughflow deposits.');
            }
            if (not $params{payment_processor}) {
                code_exit_BO('Payment processor is mandatory for doughflow deposits.');
            }
        }

        if ($ttype =~ /^(DEBIT|WITHDRAWAL_REVERSAL)$/ and not $params{payment_method}) {
            code_exit_BO("Payment method is mandatory for doughflow withdrawal and withdrawal reversals.");
        }

        $params{transaction_type} = {
            CREDIT              => 'deposit',
            DEBIT               => 'withdrawal',
            WITHDRAWAL_REVERSAL => 'withdrawal_reversal'
        }->{$ttype};
    }

    if ($payment_type eq 'mt5_adjustment') {
        $client->payment_mt5_transfer(
            %params,
            payment_type => 'mt5_transfer',
            amount       => $signed_amount,
            staff        => $clerk,
        );
    } elsif ($ttype eq 'CREDIT' || $ttype eq 'DEBIT' || $ttype eq 'WITHDRAWAL_REVERSAL') {
        my $rule_engine = BOM::Rules::Engine->new(client => $client);
        my $trx         = $client->smart_payment(
            %params,    # these are payment-type-specific params from the html form.
            amount => $signed_amount,
            staff  => $clerk,
            ($params{skip_validation} ? () : (rule_engine => $rule_engine)),
        );

        BOM::Platform::Event::Emitter::emit(
            'payment_deposit',
            {
                loginid           => $client->loginid,
                is_first_deposit  => $fdp,
                payment_processor => ($payment_type eq 'external_cashier' ? $params{payment_processor} : undef),
                transaction_id    => $trx->{id},
            }) if $ttype eq 'CREDIT';

        # Handle deposits for doughflow and bank money transfers (internal)
        # Exclude reversal transactions
        _incr_misc_checks({
                client        => $client,
                amount        => $signed_amount,
                transfer_type => $ttype
            }) if $is_internal_payment && $ttype ne 'WITHDRAWAL_REVERSAL';

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
} catch ($error) {
    # CGI::Compile will wrap the function 'exit' into a `die "EXIT\n" $errcode`
    # we should make it pass-through
    # please refer to perldoc of CGI::Compile and Try::Tiny::Except
    die $error if ref($error) eq 'ARRAY' and @$error == 2 and $error->[0] eq "EXIT\n";

    my $msg = ref $error eq 'HASH' ? $error->{message_to_client} : $error;

    print "<p>TRANSACTION ERROR: This payment violated a fundamental database rule.  Details:<br/>$msg</p>";
    printf STDERR "Error: $msg\n";
    code_exit_BO();
}

my $today = Date::Utility->today;
if ($ttype eq 'CREDIT' and $is_internal_payment) {
    # unset pa_withdrawal_explicitly_allowed for bank_wire and doughflow mannual deposit
    try {
        $client->clear_status_and_sync_to_siblings('pa_withdrawal_explicitly_allowed');
    } catch ($e) {
        $log->warn("Not able to unset payment agent explicity allowed flag for " . $client_pa_exp->loginid . ": $e");
    }
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
print qq[<p class="success">$success_message</p>];

Bar("Today's entries for $loginID");

my $from_datetime = $today->datetime_yyyymmdd_hhmmss;
my $to_datetime   = $today->plus_time_interval('1d')->datetime_yyyymmdd_hhmmss;

my $transactions = get_transactions_details({
    client => $client,
    from   => $from_datetime,
    to     => $to_datetime,
});

my $balance = client_balance($client, $client->currency);

BOM::Backoffice::Request::template()->process(
    'backoffice/account/statement.html.tt',
    {
        transactions            => $transactions,
        balance                 => $balance,
        now                     => $today,
        currency                => $client->currency,
        loginid                 => $client->loginid,
        depositswithdrawalsonly => request()->param('depositswithdrawalsonly'),
        contract_details        => \&BOM::ContractInfo::get_info,
    },
) || die BOM::Backoffice::Request::template()->error(), "\n";

#View updated statement
print "<form action=\"" . request()->url_for("backoffice/f_manager_history.cgi") . "\" method=\"post\">";
print "<input type=hidden name=loginID value='$encoded_loginID'>";
print "<input type=hidden name=\"broker\" value=\"" . encode_entities($broker) . '">';
print "<input type=hidden name=\"l\" value=\"EN\">";
print "VIEW CLIENT UPDATED STATEMENT: <input type=\"submit\" value=\"View $encoded_loginID updated statement for Today\">";
print "</form>";

if ($informclient) {
    my $subject = $ttype eq 'CREDIT' ? localize('Deposit') : localize('Withdrawal');

    my $brand = request()->brand;

    try {
        send_email({
                from          => $brand->emails('support'),
                to            => $client->email,
                subject       => $subject,
                template_name => "process_payment_notification",
                template_args => {
                    salutation   => $salutation,
                    first_name   => $first_name,
                    last_name    => $last_name,
                    subject      => $subject,
                    website_name => $brand->website_name
                },
                use_email_template    => 1,
                template_loginid      => $loginID,
                email_content_is_html => 1,
                language              => $client->user->preferred_language
            });
    } catch ($e) {
        code_exit_BO("Transaction was performed, please check client statement but an error occured while sending email. Error details $e");
    }
} elsif ($notifyclient and $payment_type eq 'external_cashier') {
    my $brand = request()->brand;
    # DEPOSIT_REVERSAL is defined as DEBIT with the deposit_reversal inside the remark
    $ttype = 'DEPOSIT_REVERSAL' if (uc $ttype) eq 'DEBIT' and $remark =~ /deposit_reversal/;

    BOM::Platform::Event::Emitter::emit(
        'payops_event_email',
        {
            event_name => 'payops_event_email',
            loginid    => $client->loginid,
            template   => 'doughflow_payment_status_update',
            properties => {
                type          => uc $ttype,
                statement_url => $brand->statement_url({language => $client->user->preferred_language}),
                live_chat_url => $brand->live_chat_url({language => $client->user->preferred_language}),
                amount        => $amount,
                currency      => $curr,
                clerk         => $clerk,
                map { $_ => $client->{$_} } qw[first_name last_name salutation]
            }});
}

code_exit_BO();

