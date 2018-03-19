#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Try::Tiny;
use Scalar::Util qw(looks_like_number);

use Brands;
use BOM::User::Client;

use BOM::Backoffice::PlackHelpers qw/PrintContentType_excel PrintContentType/;
use BOM::Backoffice::Request qw(request localize);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Utility;
use BOM::Platform::Email qw(send_email);

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('SEND EMAIL');

my %input = %{request()->params};

my ($loginid, $amount, $payment_date, $action_type, $reference_id) = @input{qw/loginid amount payment_date action_type reference_id/};

code_exit_BO("Invalid loginid!") if (not $loginid or $loginid !~ /^([A-Z]+)\d+$/);
code_exit_BO("Please provide valid amount.") unless looks_like_number($amount);
code_exit_BO("Action type can only be deposit or withdrawal.")     if (not $action_type  or $action_type !~ /^(?:deposit|withdrawal)$/);
code_exit_BO("Invalid date, date should be in yyyy-mm-dd format.") if (not $payment_date or $payment_date !~ /^(\d{4})-(\d{2})-(\d{2})$/);
code_exit_BO("Invalid reference id.")                              if (not $reference_id or $reference_id !~ /^\w+$/);

my $client = BOM::User::Client->new({loginid => $loginid}) or code_exit_BO("Error : wrong loginid ($loginid) could not get client instance");

code_exit_BO("Please provide valid loginid.") unless $client->landing_company->short eq 'japan';

$action_type = $action_type eq 'deposit' ? localize('Deposit') : localize('Withdrawal');

my $email_content;
BOM::Backoffice::Request::template->process(
    'email/japan/payment_notification.html.tt',
    {
        last_name    => $client->last_name,
        action_type  => $action_type,
        payment_date => $payment_date,
        currency     => $client->default_account->currency_code,
        amount       => $amount,
        reference_id => $reference_id,
    },
    \$email_content
) || die "payment notification email for $loginid " . BOM::Backoffice::Request::template->error;

try {
    send_email({
        from                  => Brands->new(name => request()->brand)->emails('support'),
        to                    => $client->email,
        subject               => $action_type . ' ' . localize('of funds'),
        message               => [$email_content],
        template_loginid      => $loginid,
        email_content_is_html => 1,
        use_email_template    => 1,
    });
}
catch {
    code_exit_BO("An error occured while sending email. Error details $_");
};

code_exit_BO("Email sent to $loginid: " . $client->email);
