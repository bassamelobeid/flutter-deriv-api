#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use JSON::MaybeXS;

use f_brokerincludeall;
use BOM::Database::DataMapper::Payment;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Locale;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use Syntax::Keyword::Try;
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('PROMOTIONAL TOOLS');
Bar('PROMO CODE APPROVAL TOOL');

my %input = %{request->params};
# A single request for a Bonus Approval this skips the processing  workflow and goes straight to approved or rejected.
if ($input{bonus_approve} or $input{bonus_reject}) {
    my $loginid = $input{loginid};

    my $client = BOM::User::Client->new({loginid => $loginid})
        || code_exit_BO(sprintf('<p style="color:red; font-weight:bold;">ERROR: %s</p>', $@));

    my $promo_code = $input{bonus_approve} // $input{bonus_reject};

    if ($client->promo_code eq $promo_code and $client->promo_code_status =~ /^(CLAIM|REJECT)$/) {
        code_exit_BO(
            '<p style="color:red; font-weight:bold;">ERROR: Bonus for ' . $promo_code . ' Already ' . $client->promo_code_status . 'ED. </p>');
    }
    my $encoded_promo_code = encode_entities(uc $promo_code);

    my $notify = $input{"notify"} ? 1 : 0;
    my $status;

    try {
        $client->promo_code($encoded_promo_code);
    } catch {
        code_exit_BO(sprintf('<p style="color:red; font-weight:bold;">ERROR: %s</p>', $@));
    };
    $client->promo_code_status('APPROVAL');
    if ($input{bonus_approve}) {
        $status = process_bonus_claim($client, 1, $input{amount}, $notify);
    } elsif ($input{bonus_reject}) {
        $status = process_bonus_claim($client, 0, $input{amount}, $notify);
    }

    print '<br/><b>' . $status . '<br/><br/>';

    print qq[<p>Check Another Bonus</p>
            <form action="$input{back_url}" method="get">
            Login ID: <input type="text" name="loginID" size=15 data-lpignore="true" />
            </form>]
} else {    #bulk Approval.

    my @approved = grep { /_promo$/ && $input{$_} eq 'A' } keys %input;
    my @rejected = grep { /_promo$/ && $input{$_} eq 'R' } keys %input;
    s/_promo$// for (@approved, @rejected);

    my $json = JSON::MaybeXS->new;
    my @results;
    CLIENT:
    foreach my $loginid (@approved, @rejected) {

        my $client = BOM::User::Client->new({loginid => $loginid})
            || die "bad loginid $loginid";
        my $approved = $input{"${loginid}_promo"} eq 'A';
        my $amount   = $input{"${loginid}_amount"} || next CLIENT;
        my $notify   = $input{"${loginid}_notify"} ? 1 : 0;

        push @results, process_bonus_claim($client, $approved, $amount, $notify);
    }
    print '<br/>';
    print join('<br/>', map { encode_entities($_) } @results), '<br/><br/>';
}

code_exit_BO();

=head2 process_bonus_claim

Description: Process the Bonus either approval or rejection
Takes the following arguments

=over 4

=item - $client C< BOM::User::Client >

=item - $approved Boolean true if Bonus is approved, false if rejected

=back

Returns undef

=cut

sub process_bonus_claim {
    my ($client, $approved, $amount, $notify) = @_;
    my $json        = JSON::MaybeXS->new();
    my $clerk       = BOM::Backoffice::Auth0::get_staffname();
    my $tac_url     = 'https://www.binary.com/en/terms-and-conditions.html?anchor=free-bonus#legal-binary';
    my $client_name = ucfirst join(' ', (BOM::Platform::Locale::translate_salutation($client->salutation), $client->first_name, $client->last_name));
    my $email_subject = localize("Your bonus request - [_1]", $client->loginid);
    my $email_content;
    my $loginid = $client->loginid;
    my $result;

    if ($approved) {

        return "Failed to approve $loginid: bonus amount is $amount" if $amount <= 0;
        my $cpc = $client->client_promo_code || return "Failed to approve $loginid: no promocode for client";
        my $pc  = $cpc->promotion;
        $pc->{_json} = eval { $json->decode($pc->promo_code_config) } || {};

        my $currency = $pc->{_json}->{currency}
            || return "Failed to approve $loginid: no currency for promocode $pc";
        if ($currency eq 'ALL') {
            $currency = $client->currency;
        }

        if ($client->promo_code_status eq 'APPROVAL') {
            $client->promo_code_status('CLAIM');
            $client->save();

            # credit with free gift
            $client->payment_free_gift(
                currency => $currency,
                amount   => $amount,
                remark   => 'Free gift claimed from promotional code',
                staff    => $clerk,
            );
        }

        BOM::Backoffice::Request::template()->process(
            'email/bonus_approve.html.tt',
            {
                name         => $client_name,
                currency     => $currency,
                amount       => $amount,
                tac_url      => $tac_url,
                website_name => ucfirst BOM::Config::domain()->{default_domain},
            },
            \$email_content
        ) || return "$loginid: bonus credited but send email failed: " . BOM::Backoffice::Request::template()->error;

        $result = "$loginid: bonus credited ($currency $amount)";

    } else {
        # reject client

        if ($client->promo_code_status eq 'APPROVAL') {
            $client->promo_code_status('REJECT');
            $client->save();
        }

        BOM::Backoffice::Request::template()->process(
            'email/bonus_reject.html.tt',
            {
                name         => $client_name,
                tac_url      => $tac_url,
                website_name => ucfirst BOM::Config::domain()->{default_domain},
            },
            \$email_content
        ) || return "$loginid: failed to send rejection email: " . BOM::Backoffice::Request::template()->error;

        $result = "$loginid: bonus rejected";
    }

    if ($notify) {
        send_email({
            from                  => request()->brand->emails('support'),
            to                    => $client->email,
            subject               => $email_subject,
            message               => [$email_content],
            template_loginid      => $client->loginid,
            email_content_is_html => 1,
            use_email_template    => 1,
        });
    }
    return $result;
}

1;
