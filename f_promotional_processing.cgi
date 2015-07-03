#!/usr/bin/perl
package main;
use strict 'vars';

use BOM::Platform::Runtime;
use BOM::Platform::Context;
use JSON;

use f_brokerincludeall;
use BOM::Database::DataMapper::Payment;
use BOM::Platform::Email qw(send_email);
use BOM::View::Language;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('PROMOTIONAL TOOLS');
Bar('PROMO CODE APPROVAL TOOL');

my %input = %{request->params};

BOM::Backoffice::Auth0::can_access(['Marketing']);
my $clerk = BOM::Backoffice::Auth0::from_cookie()->{nickname};

my @approved = grep { /_promo$/ && $input{$_} eq 'A' } keys %input;
my @rejected = grep { /_promo$/ && $input{$_} eq 'R' } keys %input;
s/_promo$// for (@approved, @rejected);

my $tac_url = request()->url_for(
    'c_template.cgi',
    {
        filecode     => 'legal',
        selected_tab => 'promo-tac-tab'
    });

CLIENT:
foreach my $loginid (@approved, @rejected) {

    my $client        = BOM::Platform::Client->new({loginid => $loginid}) || die "bad loginid $loginid";
    my $approved      = $input{"${loginid}_promo"} eq 'A';
    my $client_name   = ucfirst join(' ', (BOM::View::Language::translate_salutation($client->salutation), $client->first_name, $client->last_name));
    my $website       = BOM::Platform::Runtime->instance->website_list->get_by_broker_code($client->broker);
    my $email_subject = localize("Your bonus request - [_1]", $loginid);
    my $email_content;

    if ($approved) {

        my $cpc = $client->client_promo_code || die "no promocode for client $client";
        my $pc = $cpc->promotion;
        $pc->{_json} = eval { JSON::from_json($pc->promo_code_config) } || {};

        my $amount   = $pc->{_json}->{amount}   || die "no amount for promocode $pc";
        my $currency = $pc->{_json}->{currency} || die "no currency for promocode $pc";
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

        BOM::Platform::Context::template->process(
            'email/bonus_approve.html.tt',
            {
                name          => $client_name,
                currency      => $currency,
                amount        => $amount,
                support_email => BOM::Platform::Context::request()->website->config->get('customer_support.email'),
                tac_url       => $tac_url,
                website_name  => $website->name,
            },
            \$email_content
            )
            || die "approving promocode for $client: "
            . BOM::Platform::Context::template->error

    } else {
        # reject client

        if ($client->promo_code_status eq 'APPROVAL') {
            $client->promo_code_status('REJECT');
            $client->save();
        }

        BOM::Platform::Context::template->process(
            'email/bonus_reject.html.tt',
            {
                name         => $client_name,
                tac_url      => $tac_url,
                website_name => $website->name,
            },
            \$email_content
        ) || die "rejecting promocode for $client: " . BOM::Platform::Context::template->error;
    }

    if ($input{"${loginid}_notify"}) {
        send_email({
            from               => BOM::Platform::Context::request()->website->config->get('customer_support.email'),
            to                 => $client->email,
            subject            => $email_subject,
            message            => [$email_content],
            template_loginid   => $loginid,
            use_email_template => 1,
        });
        $client->add_note($email_subject, $email_content);
    }
}

print '<br/>';

print '<b>Approved : </b>', join(' ', @approved), '<br/><br/>';
print '<b>Rejected : </b>', join(' ', @rejected), '<br/><br/>';

code_exit_BO();

1;
