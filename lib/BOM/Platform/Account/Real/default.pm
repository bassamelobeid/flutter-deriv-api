package BOM::Platform::Account::Real::default;

use strict;
use warnings;
use feature 'state';
use Date::Utility;
use Locale::Country;
use Syntax::Keyword::Try;
use List::MoreUtils qw(any none);
use Text::Trim qw(trim);

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

    my $client = eval { $user->create_client(%$details) };

    unless ($client) {
        warn "Real: create_client exception [$@]";
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

            my $cur_client_lc = $cur_client->landing_company->short;
            next if ($status eq 'age_verification' && (none { $_ eq $cur_client_lc } @allowed_lc_to_sync));

            my $reason = $client->status->$status ? $client->status->$status->{reason} : 'Sync upon signup';

            # For the poi/poa flags the reason should match otherwise the BO dropdown will be unselected
            if ($status =~ /allow_po(i|a)_resubmission/) {
                $cur_client->status->set($status, 'system', $reason);
            } else {
                $cur_client->status->set($status, 'system', $reason . ' - copied from ' . $client->loginid);
            }

            my $config = request()->brand->countries_instance->countries_list->{$cur_client->residence};
            if (    $config->{virtual_age_verification}
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
        copy_status_from_siblings($client, $user,
            ['no_trading', 'withdrawal_locked', 'age_verification', 'transfers_blocked', 'allow_poi_resubmission', 'allow_poa_resubmission']);
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

    return {
        client => $client,
        user   => $user
    };
}

sub validate_account_details {
    my ($args, $client, $broker, $source) = @_;

    # If it's a virtual client, replace client with the newest real account if any
    if ($client->is_virtual) {
        $client = (sort { $b->date_joined cmp $a->date_joined } grep { not $_->is_virtual } $client->user->clients(include_disabled => 0))[0]
            // $client;
    }
    $args->{broker_code} = $broker;

    my $details = {
        broker_code                   => $broker,
        email                         => $client->email,
        client_password               => $client->password,
        myaffiliates_token_registered => 0,
        checked_affiliate_exposures   => 0,
        latest_environment            => '',
        source                        => $source,
    };

    my $affiliate_token;
    $affiliate_token = delete $args->{affiliate_token} if (exists $args->{affiliate_token});
    $details->{myaffiliates_token} = $affiliate_token || $client->myaffiliates_token || '';

    my $lc = LandingCompany::Registry->get_by_broker($broker);
    unless ($client->is_virtual) {
        for my $field (fields_to_duplicate()) {
            if ($field eq "secret_answer") {
                $args->{$field} ||= BOM::User::Utility::decrypt_secret_answer($client->$field);
            } else {
                $args->{$field} ||= $client->$field;
            }
        }
    }

    if (my @missing = grep { !$args->{$_} } required_fields($lc)) {
        return {
            error   => 'InsufficientAccountDetails',
            details => {missing => [@missing]}};
    }

    unless ($client->is_virtual) {
        my @changed;

        for my $field (fields_cannot_change()) {
            if ($args->{$field} && $client->$field) {
                my $client_field;
                if ($field eq "secret_answer") {
                    $client_field = BOM::User::Utility::decrypt_secret_answer($client->$field);
                } else {
                    $client_field = $client->$field;
                }

                push(@changed, $field) if $client_field && ($client_field ne $args->{$field});
            }
        }
        if (@changed) {
            return {
                error   => 'CannotChangeAccountDetails',
                details => {changed => [@changed]}};
        }
    }

    my $error = $client->format_input_details($args) || $client->validate_common_account_details($args) || $client->check_duplicate_account($args);
    if ($error) {
        #keep original message for create new account
        $error->{error} = 'too young' if $error->{error} eq 'BelowMinimumAge';
        #No need return duplicated account info to client, it needed in backoffice
        delete $error->{details} if $error->{error} eq 'DuplicateAccount';

        return $error;
    }

    return {error => 'P2PRestrictedCountry'}
        if ($args->{account_opening_reason} // '') eq 'Peer-to-peer exchange' & !$lc->p2p_available;

    $args->{secret_answer} = BOM::User::Utility::encrypt_secret_answer($args->{secret_answer}) if $args->{secret_answer};

    # This exist to accommodate some rules in our database (mostly NOT NULL and NULL constraints). Should change to be more consistent. Also used to filter the args to return for new account creation.
    my %default_values = (
        citizen                   => '',
        salutation                => '',
        first_name                => '',
        last_name                 => '',
        date_of_birth             => undef,
        residence                 => '',
        address_line_1            => '',
        address_line_2            => '',
        address_city              => '',
        address_state             => '',
        address_postcode          => '',
        phone                     => '',
        secret_question           => '',
        secret_answer             => '',
        place_of_birth            => '',
        tax_residence             => '',
        tax_identification_number => '',
        account_opening_reason    => '',
        place_of_birth            => undef,
        tax_residence             => undef,
        tax_identification_number => undef,
        non_pep_declaration_time  => undef,
    );

    for my $field (keys %default_values) {
        $details->{$field} = $args->{$field} // $default_values{$field};
    }

    return {details => $details};
}

=head2 required_fields

Returns an array of required fields given a landing company

=cut

sub required_fields {
    my $lc = shift;

    return $lc->requirements->{signup}->@*;
}

=head2 fields_to_duplicate

Returns an array of the fields that should be duplicated between clients

=cut

sub fields_to_duplicate {
    return
        qw(citizen salutation first_name last_name date_of_birth residence address_line_1 address_line_2 address_city address_state address_postcode phone secret_question secret_answer place_of_birth tax_residence tax_identification_number account_opening_reason);
}

=head2 fields_cannot_change

Returns an array of the fields that can't be changed if they have been set before

Note: Currently only used for citizen but will expand it's use after refactoring (or be changed completely following the clientdb -> userdb changes)

=cut

sub fields_cannot_change {
    return qw(citizen place_of_birth residence);
}

1;
