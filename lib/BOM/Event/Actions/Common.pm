package BOM::Event::Actions::Common;

=head1 NAME

BOM::Event::Actions::Common

=head1 DESCRIPTION

A set of common function between event handlers

=cut

use strict;
use warnings;

use List::Util qw( any );
use Log::Any   qw( $log );
use Template::AutoFilter;
use Syntax::Keyword::Try;
use Future::AsyncAwait;

use BOM::Config;
use BOM::Event::Utility    qw( exception_logged );
use BOM::Platform::Context qw( localize request );
use BOM::Platform::Email   qw( send_email );
use BOM::Platform::Event::Emitter;
use BOM::User::Client;
use Email::Stuffer;
use BOM::Event::Actions::P2P;
use BOM::Platform::Event::Emitter;
use BOM::Event::Actions::CustomerIO;
use Brands;
use LandingCompany::Registry;
use Carp;

# Templates prefix path
use constant TEMPLATE_PREFIX_PATH => "/home/git/regentmarkets/bom-events/share/templates/email/";

use constant ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX => 'ONFIDO::AGE::BELOW::EIGHTEEN::EMAIL::PER::USER::';

use constant PENDING_POA_EMAIL_LOCK => "PENDING::POA::EMAIL::LOCK::";

use constant PENDING_POA_EMAIL_LOCK_TTL => 604800;

=head2 set_age_verification

    This method sets the specified client as B <age_verification> .

    It also propagates the status across siblings .

    It takes the following arguments :

=over 4

=item * C<client> an instance of L<BOM::User::Client>

=item * C<provider> - the provider name which verified user's age

=back

Returns C<1> on success, C<undef> otherwise.

=cut

async sub set_age_verification {
    my ($client, $provider, $redis, $poi_method) = @_;

    croak 'poi_mehod is required' unless $poi_method;

    my $reason = "$provider - age verified";
    my $staff  = 'system';

    my $status_code = 'age_verification';

    return undef if $client->status->poi_name_mismatch;
    return undef if $client->status->poi_dob_mismatch;

    my $setter = sub {
        my $c = shift;
        if ($c->is_idv_validated) {
            $c->status->upsert($status_code, $staff, $reason);
        } else {
            $c->status->setnx($status_code, $staff, $reason);
        }
        $c->status->clear_df_deposit_requires_poi;
    };

    $log->debugf('Updating status on %s to %s (%s)', $client->loginid, $status_code, $reason);

    _email_client_age_verified($client);

    $setter->($client);

    # gb residents cannot trade synthetics on demo account while not age verified
    my $config = request->brand->countries_instance->countries_list->{$client->residence};

    if ($config->{require_age_verified_for_synthetic}) {
        my $vr_acc = BOM::User::Client->new({loginid => $client->user->bom_virtual_loginid});
        $setter->($vr_acc);
    }

    # We should sync age verification between allowed landing companies.
    # if verification poi method is supported

    my @allowed_lc_to_sync;
    for my $syncable_lc_name ($client->landing_company->allowed_landing_companies_for_age_verification_sync->@*) {
        my $syncable_lc = LandingCompany::Registry->by_name($syncable_lc_name);
        next unless any { $_ eq $poi_method } $syncable_lc->allowed_poi_providers->@*;
        push @allowed_lc_to_sync, $syncable_lc_name;
    }

    # Apply age verification for one client per each landing company since we have a DB trigger that sync age verification between the same landing companies.
    my $user = $client->user;
    my @clients_to_update =
        map { [$user->clients_for_landing_company($_)]->[0] // () } @allowed_lc_to_sync;
    foreach my $client_to_update (@clients_to_update) {
        $setter->($client_to_update);
    }

    $client->update_status_after_auth_fa($reason);

    my $key          = PENDING_POA_EMAIL_LOCK . $client->loginid;
    my $acquire_lock = await $redis->set($key, 1, 'EX', PENDING_POA_EMAIL_LOCK_TTL, 'NX');

    # After client age verification, if we find a pending POA, notify CS.
    if ($client->get_poa_status eq 'pending' && $acquire_lock) {
        _send_CS_email_POA_pending($client);
    }
    BOM::Event::Actions::P2P::p2p_advertiser_approval_changed({client => $client});

    return 1;
}

=head2 _send_CS_email_POA_pending

Sends an email to CS about a pending POA after age verification.

=cut

sub _send_CS_email_POA_pending {
    my $client = shift;

    # skip the email when is not needed
    return undef unless $client->status->age_verification;
    return undef if $client->fully_authenticated();
    return undef unless $client->landing_company->short eq 'maltainvest';

    my $brand      = request->brand;
    my $from_email = $brand->emails('no-reply');
    my $to_email   = $brand->emails('authentications');

    Email::Stuffer->from($from_email)->to($to_email)->subject('Pending POA document for: ' . $client->loginid)
        ->text_body('There is a pending proof of address document for ' . $client->loginid)->send();
}

=head2 handle_under_age_client

Apply side effects on underage clients.

It might disable the client all its related siblings if the account has no balance nor real dxtrade/mt5 accounts.

It takes the following parameters:

=over 4

=item * C<$client> - a L<BOM::User::Client> to apply side affects on

=item * C<$provider> - common name of the provider that's performing the authentication

=item * C<$from_client> - an optional L<BOM::User::Client> instance, it could be that the underage detection come from documents uploaded from a previous underage client.

=back

Returns C<undef>

=cut

sub handle_under_age_client {
    my ($client, $provider, $from_client) = @_;

    # check if there is balance
    my $siblings     = $client->real_account_siblings_information(include_disabled => 0);
    my @have_balance = grep { $siblings->{$_}->{balance} > 0 } keys $siblings->%*;
    my @mt5_loginids = $client->user->get_trading_platform_loginids('mt5',      'real');
    my @dx_loginids  = $client->user->get_trading_platform_loginids('dxtrader', 'real');
    my $loginid      = $client->loginid;

    # send livechat ticket to CS only if the account won't be disabled due to
    # having balance or deriv x or mt5 accounts.

    my $brand      = request->brand;
    my $from_email = $brand->emails('no-reply');
    my $to_email   = $brand->emails('authentications');
    my $tt         = Template::AutoFilter->new({
        ABSOLUTE => 1,
        ENCODING => 'utf8'
    });
    my $subject = "Underage client detection $loginid";

    my $data = {
        have_balance => [map { $siblings->{$_} } @have_balance],
        mt_loginids  => [@mt5_loginids],
        dx_loginids  => [@dx_loginids],
        loginid      => $loginid,
        title        => $subject,
        from_client  => $from_client,
    };

    # We will send an LC ticket to authentications if the client has real balance
    # or a real dervix/mt5 account.
    # Otherwise, we'll disable and notify the client.
    my $send_lc_ticket = @have_balance || @dx_loginids || @mt5_loginids;

    if ($send_lc_ticket) {
        try {
            $tt->process(BOM::Event::Actions::Common::TEMPLATE_PREFIX_PATH . 'underage_client_detection.html.tt', $data, \my $html);
            die "Template error: @{[$tt->error]}" if $tt->error;

            die "failed to send underage detection email ($loginid)"
                unless Email::Stuffer->from($from_email)->to($to_email)->subject($subject)->html_body($html)->send();
        } catch ($e) {
            $log->warn($e);
            exception_logged();
        }
    } else {
        # push the virtual
        $siblings->{$client->user->bom_virtual_loginid} = undef if $client->user->bom_virtual_loginid;

        # if all of the account doesn't have any balance, disable them
        for my $each_siblings (keys %{$siblings}) {
            my $current_client = BOM::User::Client->new({loginid => $each_siblings});
            my $reason         = sprintf("%s - client is underage", $provider);

            $reason = sprintf("%s - client is underage - same documents as %s", $provider, $from_client->loginid) if $from_client;

            $current_client->status->setnx('disabled', 'system', $reason);
        }

        # need to send email to client
        my $brand  = request->brand;
        my $params = {
            language => uc($client->user->preferred_language // request->language // 'en'),
        };

        BOM::Platform::Event::Emitter::emit(
            underage_account_closed => {
                loginid    => $client->loginid,
                properties => {
                    tnc_approval => $brand->tnc_approval_url($params),
                }});
    }

    return undef;
}

=head2 _email_client_age_verified

Emails client when they have been successfully age verified.
Raunak 19/06/2019 Please note that we decided to do it as frontend notification but since that is not yet drafted and designed so we will implement email notification

=over 4

=item * L<BOM::User::Client>  Client Object of user who has been age verified.

=back

Returns undef

=cut

sub _email_client_age_verified {
    my ($client) = @_;

    my $brand = request->brand;

    return unless $client->landing_company()->{actions}->{account_verified}->{email_client};

    return if $client->status->age_verification;

    # p2p will handle notification for this case
    return if ($client->status->reason('allow_document_upload') // '') eq 'P2P_ADVERTISER_CREATED';

    my $website_name = $brand->website_name;

    try {
        BOM::Platform::Event::Emitter::emit(
            age_verified => {
                loginid    => $client->loginid,
                properties => {
                    email         => $client->email,
                    name          => $client->first_name,
                    website_name  => $website_name,
                    contact_url   => $brand->contact_url({language => uc($client->user->preferred_language // request->language // 'en')}),
                    poi_url       => $brand->authentication_url({language => uc($client->user->preferred_language // request->language // 'en')}),
                    live_chat_url => $brand->live_chat_url({language => uc($client->user->preferred_language // request->language // 'en')}),
                }});
    } catch ($e) {
        $log->warn($e);
        exception_logged();
    }

    return undef;
}

=head2 trigger_cio_broadcast

Triggers a customer.io broadcast campaign.
Only triggering by user ids is supported for now.

=cut

sub trigger_cio_broadcast {
    my $data = shift;

    my $campaign_id = delete $data->{campaign_id};
    unless ($campaign_id) {
        $log->warn('No campaign_id provided to trigger_cio_broadcast');
        return 0;
    }

    if (my $ids = delete $data->{ids}) {
        return BOM::Event::Actions::CustomerIO->new->trigger_broadcast_by_ids($campaign_id, $ids, $data);
    }

    $log->warn('No valid recipients provided to trigger_cio_broadcast');
    return 0;
}

1;
