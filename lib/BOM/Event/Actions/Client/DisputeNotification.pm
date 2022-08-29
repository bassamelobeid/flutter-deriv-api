package BOM::Event::Actions::Client::DisputeNotification;

use strict;
use warnings;

=head1 NAME

BOM::Event::Actions::Client::DisputeNotification

=head1 DESCRIPTION

Provides handlers for dispute notifications-related events received. 

=cut

no indirect;

use Log::Any qw($log);
use DataDog::DogStatsd::Helper;
use Syntax::Keyword::Try;

use BOM::Platform::Email qw(send_email);
use BOM::Event::Utility  qw(exception_logged);

# this one should come after BOM::Platform::Email
use Email::Stuffer;

use constant TEMPLATE_PREFIX_PATH => "/home/git/regentmarkets/bom-events/share/templates/email/";

use constant STAT_KEY_PREFIX => "event.dispute_notification.";

my %notification_handlers = (
    'acquired'  => \&_handle_acquired,
    'isignthis' => \&_handle_isignthis,
);

=head2 dispute_notification

Handle any dispute notification. Currently sending an e-mail to Payments 

=over 4

=item * C<args> - A hashref with the information received from dispute provider. 

=back

=head2 The hashref contains the following field

=over 4

=item * C<provider> -  A string with the provider name. Currently only B<acquired>. 

=item * C<data> -  A hashref to the payload as sent by the provider.

=back

returns, undef.

=cut

sub dispute_notification {

    my $args = shift;
    my ($provider, $data) = @{$args}{qw/provider data/};

    my $handler = $notification_handlers{$provider};

    if ($handler) {
        $handler->($data);
    } else {
        DataDog::DogStatsd::Helper::stats_inc(STAT_KEY_PREFIX . "unsupported_provider.${provider}");
        $log->warnf("Received dispute_notification from an unknown provider '%s'", $provider);
    }

    return undef;
}

=head2 _handle_acquired 

Handle data send by Acquired.com. Events and payloads are described in https://developer.acquired.com/integrations/webhooks#events

B<Important> We are only supporting the B<fraud_new> and B<dispute_new>.

=over 4

=item * C<args> - A hashref data received from acquired.

=back

=head3 Data received from acquired

=over 4

=item * C<id> - A string with the unique reference for the webhook.

=item * C<timestamp> - A string with the timestamp of webhook.

=item * C<company_id> - A string with the integer identifier issued to merchants. (This is our company id)

=item * C<hash> - A string with the verification hash.

=item * C<event> - A string with the event for which the webhook is being triggered. Currently we only support B<fraud_new> and B<dispute_new>.

=item * C<list> - An arrayref of hashrefs described below. 

=back

=head2 Every hashref in lists:

=over 4

=item * C<mid> - A string with the integer merchant ID the transaction was processed through.

=item * C<transaction_id> - A string with the integer unique ID generated to identify the transaction. 

=item * C<merchant_order_id> - A string with unique value we'll use to identify each transaction, repeated from the request.

=item * C<parent_id> - A string with the transaction_id generated by Acquired  and returned in the original request.

=item * C<arn> - A string value set by the acquirer to track the transaction (optional) 

=item * C<rrn> - A string value set by the acquirer to track the transaction (optional)

=item * C<fraud> - A hashref with the fraud information (only if C<event> is B<fraud_new>)

=item * C<dispute> - A hashref with the dispute information (only if C<event> is B<dispute_new>)

=back

=head2 Every fraud hashref has the following attributes

=over 4

=item * C<fraud_id> - A string with the unique ID generated to identify the dispute.

=item * C<date> -  A string with the date and time of dispute submission.

=item * C<amount> -  A string with the transaction amount.

=item * C<currency> -  A string with the transaction currency, following ISO 4217 (3 digit code).

=item * C<auto_refund> - True/False value stating whether or not the transactionhas been auto refunded.

=back 

=head2 Every dispute hashref have the following attributes

=over 4

=item * C<dispute_id> - A string with the unique ID generated to identify the dispute.

=item * C<reason_code> - A string with the dispute category and/or condition.

=item * C<description> - A string with the description of dispute category and/or condition.

=item * C<date> -  A string with the date and time of dispute submission.

=item * C<amount> -  A string with the transaction amount.

=item * C<currency> -  A string with the transaction currency, following ISO 4217 (3 digit code).

=back

=over 4

=item * C<history> - A hashref with the historical reference of this dispute.

=back

=head2 Every history hashref has the following attributes

=over 4

=item * C<retrieval_id> - A string with the unique ID Acquired generated to identifiy the retrieval of the dispute (optional)

=item * C<fraud_id> - A string with the unique ID Acquired generated to identify the fraud (optional)

=item * C<dispute_id> - A string with the value set by the acquirer to track the dipsute (optional)

=back

Returns, undef.

=cut 

sub _handle_acquired {
    my $data  = shift;
    my $event = $data->{event};
    if (!($event eq 'fraud_new' || $event eq 'dispute_new')) {
        DataDog::DogStatsd::Helper::stats_inc(STAT_KEY_PREFIX . "acquired.unsupported.${event}");
        return undef;
    }

    my ($timestamp, $company_id, $list) =
        @{$data}{qw/timestamp company_id list/};
    $timestamp =~ s/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/$1-$2-$3 $4:$5:$6/;

    my $payload = {
        timestamp  => $timestamp,
        company_id => $company_id,
        event      => $event,
        list       => $list,
    };

    my $subject;
    my $template_path;
    if ($event eq 'fraud_new') {
        $subject       = 'New Fraud';
        $template_path = TEMPLATE_PREFIX_PATH . 'acquired_new_fraud.html.tt';
    } else {
        $subject       = 'New Dispute';
        $template_path = TEMPLATE_PREFIX_PATH . 'acquired_new_dispute.html.tt';
    }

    my $tt = Template->new(ABSOLUTE => 1);
    try {
        $tt->process($template_path, $payload, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;
        send_email({
            from                  => 'no-reply@deriv.com',
            to                    => 'x-cs@deriv.com,x-payops@deriv.com',
            subject               => $subject,
            message               => [$html],
            use_email_template    => 0,
            email_content_is_html => 1,
            skip_text2html        => 1,
        });
    } catch ($error) {
        $log->warnf("Error handling an event from 'acquired.com'. Details: $error");
        exception_logged();
    }

    return undef;
}

=head2 _handle_isignthis 

Handle data send by iSignThis. Events and payloads are described in https://docs.api.isignthis.com/notification/

=over 4

=item * C<args> - A hashref of data received from iSignThis.

=back

=head3 Data received from iSignThis. 

=over 4

=item * C<id> - A string with the unique response identification code.

=item * C<secret> - A string with the transaction secret code.

=item * C<mode> - A string with the transaction mode detected by iSignthis.

=item * C<recurring_transaction> - A boolean value describing whether the transaction was a recurring operation or not.

=item * C<original_message> - An object with information about your transaction request.

=item * C<workflow_state> - An object with state information about the workflow.

=item * C<event> - A string with the event name of the notification. See https://docs.api.isignthis.com/events/ for more information. Currently we only support B<chargeback_flagged>, B<dispute_flagged>, B<fraud_flagged> and B<manual_risk_review>

=item * C<state> - A string State of the transaction.

=item * C<compound_state> - A string with the compound state of the transaction.

=item * C<card_reference> - An object with information of the card that was used

=item * C<payment_provider_responses> - An array with information about payments or credits made.

=item * C<payment_amount> - An object with the original requested payment amount

=item * C<identity> - An object with information about the identity.

=item * C<response_code> - A string with the response code of the transaction.

=item * C<response_code_description> - A string with the response code description.

=item * C<test_transaction> - A boolean value that denotes use of Test Card.

=back

=head4 The C<original_message> object contains:

=over 4

=item * C<merchant_id> - A string with the merchant identifier.

=item * C<transaction_id> - A string with the original transaction identifier.

=item * C<reference> - A string with the original reference.

=item * C<account> - An object with account details

=back

=head2 The C<account> object contains:

=over 4

=item * C<identifier> - A string value with the account identifier 

=item * C<ext> -  An object with extra information. Content depends on the original message.

=back

=head2 The C<workflow_state> object contains:

The attributers may describe if a step in the workflow is not applicable B<NA> or skipped B<SKIPPED> or accepted B<ACCEPTED>.

=over 4

=item C<capture> - A string. Capture is not applicable.

=item C<charge> - A string. Charge process has been accepted.

=item C<credit> - A string. Credit is not applicable.

=item C<3ds> - A string. 3ds is not applicable.

=item C<piv> - A string. Piv is not applicable.

=item C<sca> - A string. Sca has been skipped.

=item C<docs> - A string. Docs is not applicable.

=item C<kyc> - A string. KYC verification has been accepted.

=back

=head2 The C<card_reference> object contains:

=over 4

=item * C<masked_pan> - A string value with the Private Account Number.

=item * C<card_brand> - A string value with the card brand.

=item * C<expiry_date> -  A string value with the expiry date for the card.

=item * C<recurring_id> - A string value with the recurring identifier. 

=back

=head2 Every C<payment_provider_response> item is an object that contains:

=over 4

=item * C<operation_type> - A string describing The operation type.

=item * C<operation_successful> - A boolean, indicates whether the operation was successful or not.

=item * C<provider_type> - A string with the type of payment instrument.

=item * C<provider_name> - A string with the name of the Payment Provider.

=item * C<request_currency> - A string with the ISO 4217 currency code of the requested currency.

=item * C<reference_code> - A string  with the unique reference code for the transaction.

=item * C<provider_reference_code> - A string with the identifier issued by the payment provider for this operation.

=item * C<response_id> - A string with the response identifier.

=item * C<status_code> - A string with the status code returned from payment provider.

=item * C<status_description> - A string with the status code description.

=back

=head2 The C<payment_amount> object contains:

=over 4

=item * C<currency> - A string value describing the transaction currency.

=item * C<amount> - A numeric value describing the transaction amount 

=back

=head2 The C<identity> object contains:

=over 4

=item * C<id> - A string value with an unique identifier.

=item * C<download_url> - A string with an url to download the identity information.

=item * C<ledger_lifetime_ammount> - A string with a numeric value describing ledger lifetime amount.

=item * C<ledger_lifetime_currency> - A string describing the ledger lifetime currency.

=item * C<credit_ledger_lifetime_amount> - A string with numeric value describing credit ledger lifetime amount.

=item * C<credit_ledger_lifetime_amount> - A string describing the credit ledger lifetime currencyl.

=item * C<kyc_state> - A string with KYC state.

=item * C<created_at> - A string with ISO-8601 UTC date.

=back

Returns, undef.

=cut 

sub _handle_isignthis {
    my $data = shift;
    my ($fraud_event, $dispute_event) = ("fraud_flagged", "dispute_flagged", "chargeback_flagged", "manual_risk_review");
    my $event = $data->{event};
    if (!($event eq $fraud_event || $event eq $dispute_event)) {
        DataDog::DogStatsd::Helper::stats_inc(STAT_KEY_PREFIX . "isignthis.unsupported.${event}");
        return undef;
    }

    my $subject;
    my $template_path = TEMPLATE_PREFIX_PATH . 'isignthis_new_notification.html.tt';
    if ($event eq $fraud_event) {
        $subject = 'New Fraud';
    } else {
        $subject = 'New Dispute';
    }

    my $tt = Template->new(ABSOLUTE => 1);
    try {
        $tt->process($template_path, $data, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;
        send_email({
            from                  => 'no-reply@deriv.com',
            to                    => 'x-cs@deriv.com,x-payops@deriv.com',
            subject               => $subject,
            message               => [$html],
            use_email_template    => 0,
            email_content_is_html => 1,
            skip_text2html        => 1,
        });
    } catch ($error) {
        $log->warnf("Error handling an event from 'iSignThis'. Details: $error");
        exception_logged();
    }

    return undef;
}

1;
