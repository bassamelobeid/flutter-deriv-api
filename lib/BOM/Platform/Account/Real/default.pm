package BOM::Platform::Account::Real::default;

use strict;
use warnings;
use feature 'state';
use Date::Utility;
use Locale::Country;
use Syntax::Keyword::Try;
use List::MoreUtils qw(any none);
use Text::Trim      qw(trim);
use Log::Any        qw($log);

use BOM::User::Client;
use BOM::User::Phone;

use BOM::Database::ClientDB;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Client::Sanctions;
use BOM::User::FinancialAssessment;
use List::Util qw(uniq);

sub create_account {
    my $args = shift;
    my ($user, $details) = @{$args}{'user', 'details'};

    my $account_type_name = $details->{account_type} or return {error => {code => 'AccountTypeMissing'}};    # default to 'trading'
    my $account_type      = BOM::Config::AccountType::Registry->account_type_by_name($account_type_name)
        or return {error => {code => 'InvalidAccountType'}};

    if ($account_type->name ne 'binary' and $account_type->category->name eq 'trading') {
        my $wallet = delete $args->{wallet} || die 'Trading account cannot be orphant';
        $details->{wallet_loginid} = $wallet->loginid;
    }

    my $client;
    try {
        if ($account_type->name eq 'affiliate') {
            $client = $user->create_affiliate(%$details);
        } elsif ($account_type->category->name eq 'wallet') {
            $client = $user->create_wallet(%$details);
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

=head2 copy_status_from_siblings

copy statuses from client siblings

=over 4

=item C<cur_client> current client object.

=item C<status_list> list of statuses to be copied.

=item C<from_dup_only> a list of statuses to be copied only from dup accunts.

=back

=cut

sub copy_status_from_siblings {
    my ($cur_client, $status_list, $from_dup_only) = @_;
    $from_dup_only //= [];

    my @allowed_lc_to_sync;

    my $user = $cur_client->user;

    my @client_list = $user->clients;

    my $vr_loginid = $user->bom_virtual_loginid;

    my $vr_client;

    $vr_client = BOM::User::Client->new({loginid => $vr_loginid}) if $vr_loginid;

    my $duplicated_client;

    $duplicated_client = $vr_client->duplicate_sibling_from_vr() if $vr_client;

    push @client_list, $duplicated_client if $duplicated_client;

    # We should sync age verification for allowed landing companies and other statuses to all siblings
    # Age verification sync if current client is one of existing client allowed landing companies for age verification
    for my $client (@client_list) {
        @allowed_lc_to_sync = (
            $client->landing_company->allowed_landing_companies_for_age_verification_sync->@*,
            $client->landing_company->short,    #Always sync age verification within the same landing company
        );
        my @dup_statuses = ();

        @dup_statuses = @$from_dup_only if $duplicated_client && $client->loginid eq $duplicated_client->loginid;

        for my $status (uniq(@$status_list, @dup_statuses)) {
            next unless $client->status->$status;
            next if $client->status->$status && $cur_client->status->$status;

            if ($status eq 'age_verification') {
                my $cur_client_lc = $cur_client->landing_company->short;
                next if none { $_ eq $cur_client_lc } @allowed_lc_to_sync;

                # If clients in the same DB, it's already copied over by the db trigger
                next if $cur_client->broker_code eq $client->broker_code;

                my $poi_status = $client->get_poi_status({landing_company => $cur_client->landing_company->short});
                next unless $poi_status =~ /verified|expired/;
            }

            my $reason = $client->status->$status ? $client->status->$status->{reason} : 'Sync upon signup';

            # For the poi/poa flags the reason should match otherwise the BO dropdown will be unselected
            if ($status =~ /allow_po(i|a)_resubmission/ || $status =~ /poi_(.*)_mismatch/ || $status eq 'financial_risk_approval') {
                $cur_client->status->upsert($status, 'system', $reason);
            } else {
                $cur_client->status->upsert($status, 'system', $reason . ' - copied from ' . $client->loginid);
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

=head2 copy_data_to_siblings

Back populate data to client siblings if new data is added

=over 4

=item C<cur_client> current client object.

=item C<sibling> sibling object.

=back

=cut

sub copy_data_to_siblings {
    my ($cur_client) = @_;
    my @fields_to_back_populate =
        qw(residence address_line_1 address_line_2 address_city address_state address_postcode phone place_of_birth date_of_birth citizen salutation first_name last_name secret_answer secret_question);
    my @tax_and_account_opening_reason_fields_to_back_populate = qw(account_opening_reason tax_residence tax_identification_number);

    for my $sibling ($cur_client->user->clients) {
        try {
            next if $sibling->is_virtual;
            next if $sibling->loginid eq $cur_client->loginid;
            for my $field (@fields_to_back_populate) {
                if (!$sibling->$field && $cur_client->$field) {
                    $sibling->$field($cur_client->$field);
                }
            }
            # Always populate tax information to siblings
            for my $field (@tax_and_account_opening_reason_fields_to_back_populate) {
                my $current_value = $cur_client->$field // '';
                my $sibling_value = $sibling->$field    // '';
                $sibling->$field($current_value) if $current_value ne $sibling_value && $current_value ne '';
            }
            $sibling->save();
        } catch ($e) {
            $log->errorf("Error caught when back-populating data back to siblings: ", $e);
        }
    }
}

sub after_register_client {
    my $args = shift;
    my ($client, $user) = @{$args}{qw(client user details ip country)};
    unless ($client->is_virtual) {
        $client->user->set_tnc_approval;
        copy_status_from_siblings(
            $client,
            [
                'no_trading',               'withdrawal_locked',      'age_verification',        'transfers_blocked',
                'allow_poi_resubmission',   'allow_poa_resubmission', 'potential_fraud',         'poi_name_mismatch',
                'poi_dob_mismatch',         'cashier_locked',         'unwelcome',               'no_withdrawal_or_trading',
                'internal_client',          'shared_payment_method',  'df_deposit_requires_poi', 'poi_name_mismatch',
                'smarty_streets_validated', 'address_verified',       'poi_dob_mismatch',        'cooling_off_period',
                'poi_poa_uploaded',         'poa_address_mismatch'
            ],
            ['financial_risk_approval']);
        copy_data_to_siblings($client);

        my $vr_loginid = $user->bom_virtual_loginid;

        my $vr_client;

        $vr_client = BOM::User::Client->new({loginid => $vr_loginid}) if $vr_loginid;

        my $duplicated_client;

        $duplicated_client = $vr_client->duplicate_sibling_from_vr() if $vr_client;

        BOM::User::FinancialAssessment::copy_financial_assessment($duplicated_client, $client) if $duplicated_client;
    }

    BOM::Platform::Client::Sanctions->new({
            client => $client,
            brand  => request()->brand
        })->check();

    BOM::Platform::Client::IDAuthentication->new(client => $client)->run_validation('signup');

    set_allow_document_upload($client);

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
