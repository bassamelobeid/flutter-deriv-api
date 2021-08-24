package BOM::Event::Actions::Common;

=head1 NAME

BOM::Event::Actions::Common

=head1 DESCRIPTION

A set of common function between event handlers

=cut

use strict;
use warnings;

use List::Util qw( any );
use Log::Any qw( $log );
use Template::AutoFilter;
use Syntax::Keyword::Try;

use BOM::Config;
use BOM::Event::Utility qw( exception_logged );
use BOM::Platform::Context qw( localize request );
use BOM::Platform::Email qw( send_email );
use BOM::Platform::Event::Emitter;
use BOM::User::Client;

use Brands;

# Templates prefix path
use constant TEMPLATE_PREFIX_PATH => "/home/git/regentmarkets/bom-events/share/templates/email/";

use constant ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX => 'ONFIDO::AGE::BELOW::EIGHTEEN::EMAIL::PER::USER::';

=head2 set_age_verification

This method sets the specified client as B<age_verification>.

It also propagates the status across siblings.

It takes the following arguments:

=over 4

=item * C<client> an instance of L<BOM::User::Client>

=item * C<provider> - the provider name which verified user's age

=back

Returns undef.

=cut

sub set_age_verification {
    my ($client, $provider) = @_;

    my $reason = "$provider - age verified";
    my $staff  = 'system';

    my $status_code = 'age_verification';

    return undef if $client->status->poi_name_mismatch;

    my $setter = sub {
        my $c = shift;
        $c->status->upsert($status_code, $staff, $reason) if $client->status->is_experian_validated;
        $c->status->setnx($status_code, $staff, $reason) unless $client->status->is_experian_validated;
    };

    $log->debugf('Updating status on %s to %s (%s)', $client->loginid, $status_code, $reason);

    # to push FE notification when advertiser becomes approved via db trigger
    BOM::Platform::Event::Emitter::emit('p2p_advertiser_updated', {client_loginid => $client->loginid});

    _email_client_age_verified($client);

    $setter->($client);

    # gb residents cannot trade synthetics on demo account while not age verified
    my $config = request->brand->countries_instance->countries_list->{$client->residence};
    if ($config->{require_age_verified_for_synthetic}) {
        my $vr_acc = BOM::User::Client->new({loginid => $client->user->bom_virtual_loginid});
        $setter->($vr_acc);
    }

    # We should sync age verification between allowed landing companies.

    my @allowed_lc_to_sync = @{$client->landing_company->allowed_landing_companies_for_age_verification_sync};
    # Apply age verification for one client per each landing company since we have a DB trigger that sync age verification between the same landing companies.
    my @clients_to_update =
        map { [$client->user->clients_for_landing_company($_)]->[0] // () } @allowed_lc_to_sync;
    $setter->($_) foreach (@clients_to_update);

    $client->update_status_after_auth_fa($reason);

    return undef;
}

sub handle_under_age_client {
    my ($client, $provider, $reported_dob) = @_;

    my $siblings = $client->real_account_siblings_information(include_disabled => 0);

    # check if there is balance
    my $have_balance = (any { $siblings->{$_}->{balance} > 0 } keys %{$siblings}) ? 1 : 0;

    my $email_details = {
        client         => $client,
        short_reason   => 'under_18',
        failure_reason => "because $provider reported the date of birth as $reported_dob which is below age 18.",
        redis_key      => ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $client->binary_user_id,
        is_disabled    => 0,
        account_info   => $siblings,
    };

    unless ($have_balance) {
        # if all of the account doesn't have any balance, disable them
        for my $each_siblings (keys %{$siblings}) {
            my $current_client = BOM::User::Client->new({loginid => $each_siblings});
            $current_client->status->setnx('disabled', 'system', "$provider - client is underage");
        }

        # need to send email to client
        _send_email_underage_disable_account($client);

        $email_details->{is_disabled} = 1;
    }
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

    my $from_email   = $brand->emails('no-reply');
    my $website_name = $brand->website_name;

    my $data_tt = {
        client       => $client,
        l            => \&localize,
        website_name => $website_name,
        contact_url  => $brand->contact_url,
    };
    my $email_subject = localize("Your identity is verified");
    my $tt            = Template->new(ABSOLUTE => 1);

    try {
        $tt->process(TEMPLATE_PREFIX_PATH . 'age_verified.html.tt', $data_tt, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;
        send_email({
                from          => $from_email,
                to            => $client->email,
                subject       => $email_subject,
                message       => [$html],
                template_args => {
                    name  => $client->first_name,
                    title => localize("Your identity is verified"),
                },
                use_email_template    => 1,
                email_content_is_html => 1,
                skip_text2html        => 1,
            });
    } catch ($e) {
        $log->warn($e);
        exception_logged();
    }

    return undef;
}

sub _send_email_underage_disable_account {
    my ($client) = @_;

    my $website_name  = ucfirst BOM::Config::domain()->{default_domain};
    my $email_subject = localize("Your account has been closed");
    my $brand         = request->brand;

    my $params = {
        language => request->language,
    };

    send_email({
            to            => $client->email,
            subject       => $email_subject,
            template_name => 'close_account_underage',
            template_args => {
                website_name => $website_name,
                tnc_approval => $brand->tnc_approval_url($params),
                name         => $client->first_name,
                title        => localize("We've closed your account"),
            },
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 1,
        });

    return undef;
}

1;
