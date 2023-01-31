package BOM::Platform::Account::Real::default;

use strict;
use warnings;
use feature 'state';
use Date::Utility;
use Locale::Country;
use Syntax::Keyword::Try;
use List::MoreUtils qw(any none);
use Text::Trim      qw(trim);

use BOM::User::Client;
use BOM::User::Phone;

use BOM::Database::ClientDB;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Client::Sanctions;

sub create_account {
    my $args = shift;
    my ($user, $details) = @{$args}{'user', 'details'};

    my $type = delete $details->{type} // 'trading';

    my $client;
    try {
        if ($type eq 'wallet') {
            $client = $user->create_wallet(%$details);
        } elsif ($type eq 'affiliate') {
            $client = $user->create_affiliate(%$details);
        } else {
            $client = $user->create_client(%$details);
        }
    } catch ($e) {
        return $e if ref $e eq 'HASH' && $e->{error};

        warn "Real account creation exception [$e]";
        return {error => 'invalid'};
    }

    my $response = after_register_client({
        client  => $client,
        user    => $user,
        details => $details,
        ip      => $args->{ip},
        country => $args->{country},
    });

    return $response;
}

sub copy_status_from_siblings {
    my ($cur_client, $user, $status_list) = @_;
    my @allowed_lc_to_sync;

    # We should sync age verification for allowed landing companies and other statuses to all siblings
    # Age verification sync if current client is one of existing client allowed landing companies for age verification
    for my $client ($user->clients) {
        @allowed_lc_to_sync = @{$client->landing_company->allowed_landing_companies_for_age_verification_sync};
        for my $status (@$status_list) {
            next unless $client->status->$status;
            next if $client->status->$status && $cur_client->status->$status;

            if ($status eq 'age_verification') {
                my $cur_client_lc = $cur_client->landing_company->short;
                next if none { $_ eq $cur_client_lc } @allowed_lc_to_sync;
                my $poi_status = $client->get_poi_status({landing_company => $cur_client->landing_company->short});
                next unless $poi_status =~ /verified|expired/;
            }

            my $reason = $client->status->$status ? $client->status->$status->{reason} : 'Sync upon signup';

            # For the poi/poa flags the reason should match otherwise the BO dropdown will be unselected
            if ($status =~ /allow_po(i|a)_resubmission/) {
                $cur_client->status->set($status, 'system', $reason);
            } else {
                $cur_client->status->set($status, 'system', $reason . ' - copied from ' . $client->loginid);
            }

            my $config = request()->brand->countries_instance->countries_list->{$cur_client->residence};
            if (    $config->{require_age_verified_for_synthetic}
                and $status eq 'age_verification')
            {
                my $vr_acc = BOM::User::Client->new({loginid => $cur_client->user->bom_virtual_loginid});
                $vr_acc->status->clear_unwelcome;
                $vr_acc->status->setnx('age_verification', 'system', $reason . ' - copied from ' . $client->loginid);
            }
        }
    }
}

sub after_register_client {
    my $args = shift;
    my ($client, $user) = @{$args}{qw(client user details ip country)};

    unless ($client->is_virtual) {
        $client->user->set_tnc_approval;
        copy_status_from_siblings(
            $client, $user,
            [
                'no_trading',             'withdrawal_locked',      'age_verification', 'transfers_blocked',
                'allow_poi_resubmission', 'allow_poa_resubmission', 'potential_fraud'
            ]);
    }

    BOM::Platform::Client::Sanctions->new({
            client => $client,
            brand  => request()->brand
        })->check();

    my $client_loginid = $client->loginid;

    if ($client->landing_company->short eq 'iom'
        and (length $client->first_name < 3 or length $client->last_name < 3))
    {
        my $notemsg = "$client_loginid - first name or last name less than 3 characters \n\n\n\t\t";
        $notemsg .= join("\n\t\t",
            'first name: ' . $client->first_name,
            'last name: ' . $client->last_name,
            'residence: ' . Locale::Country::code2country($client->residence));
        $client->add_note("MX Client [$client_loginid] - first name or last name less than 3 characters", "$notemsg\n");
    }

    BOM::Platform::Client::IDAuthentication->new(client => $client)->run_validation('signup');

    BOM::User::Utility::set_gamstop_self_exclusion($client);

    set_allow_document_upload($client) if $client->account_type eq 'trading';

    return {
        client => $client,
        user   => $user
    };
}

=head2 set_allow_document_upload

Sets client's status to allow_document_upload if the client's residence or citizenship allow MT5 account
creation in regulated landing companies.

=over 4

=item * C<$client> - BOM::User::Client object.

=back

=cut

sub set_allow_document_upload {
    my $client = shift;

    # well, prioritise citizen over residence.
    my $country_code = $client->citizen || $client->residence;
    if (request()->brand->countries_instance->has_mt_regulated_company_for_country($country_code)) {

        # If client country code is Non IDV supported and broker code is CR
        if ((!request()->brand->countries_instance->is_idv_supported($country_code)) && $client->broker_code eq 'CR') {
            $client->status->upsert('allow_document_upload', 'system', 'CR_CREATION_FOR_NON_IDV_COUNTRIES');
        } else {
            $client->status->upsert('allow_document_upload', 'system', 'MARKED_AS_NEEDS_ACTION');
        }

    }

    return;
}

1;
