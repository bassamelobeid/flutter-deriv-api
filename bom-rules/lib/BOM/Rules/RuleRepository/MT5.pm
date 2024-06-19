package BOM::Rules::RuleRepository::MT5;

=head1 NAME

BOM::Rules::RuleRepositry::MT5

=head1 DESCRIPTION

This modules declares rules and regulations pertaining the MT5.

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);
use BOM::Config::TradingPlatform::KycStatus;
use BOM::Config::TradingPlatform::Jurisdiction;
use Time::Moment;
use Date::Utility;
use List::Util qw( any all none );

rule 'mt5_account.account_poa_status_allowed' => {
    description => 'Checks if mt5 accounts are considered valid by poa status and jurisdiction',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client                        = $context->client($args);
        my $mt5_jurisdiction              = $args->{mt5_jurisdiction};
        my $mt5_id                        = $args->{mt5_id};                                     # mt5_id will overwrite the mt5_jurisdiction
        my %loginid_details               = %{$args->{loginid_details}};
        my $error_message                 = 'POAVerificationFailed';
        my $kyc_status_config             = BOM::Config::TradingPlatform::KycStatus->new();
        my $jurisdiction_config           = BOM::Config::TradingPlatform::Jurisdiction->new();
        my @trading_platform_kyc_statuses = $kyc_status_config->get_kyc_status_list();
        my @jurisdictions_list            = $jurisdiction_config->get_jurisdiction_list_with_grace_period();

        die 'If mt5_id is provided, mt5_jurisdiction should not be provided' if defined $mt5_id and defined $mt5_jurisdiction;

        if (defined $mt5_id and exists $loginid_details{$mt5_id}) {
            return 1 if ($loginid_details{$mt5_id}->{account_type} // '') eq 'demo';
            return 1 unless defined $loginid_details{$mt5_id}->{attributes}->{group};
            my $jurisdictions_regex = join('|', @jurisdictions_list);
            ($mt5_jurisdiction) = $loginid_details{$mt5_id}->{attributes}->{group} =~ m/($jurisdictions_regex)/g;
        }

        my $grace_period;
        $grace_period = $jurisdiction_config->get_jurisdiction_grace_period($mt5_jurisdiction)
            if defined $mt5_jurisdiction and $jurisdiction_config->is_jurisdiction_grace_period_enforced($mt5_jurisdiction);
        return 1 unless defined $grace_period;

        my $poa_status = $client->get_poa_status(undef, $mt5_jurisdiction);
        return 1 if $poa_status eq 'verified';
        return 1
            if $poa_status eq 'expired'
            && !$client->is_high_risk
            && $client->fully_authenticated({landing_company => $mt5_jurisdiction});

        if (defined $mt5_id) {
            my $selected_mt5_status = $loginid_details{$mt5_id}->{status} // 'active';

            # active accounts might have to look back into the authentication status
            return 1
                unless any { $selected_mt5_status eq $_ } ('active', @trading_platform_kyc_statuses);
        }

        my @mt5_accounts =
            grep {
                    ($loginid_details{$_}->{platform} // '') eq 'mt5'
                and $loginid_details{$_}->{account_type} eq 'real'
                and $loginid_details{$_}->{attributes}->{group} =~ m/$mt5_jurisdiction/
            } keys %loginid_details;

        my $current_datetime = Date::Utility->new(Date::Utility->new->datetime);

        $self->fail($error_message, params => {mt5_status => 'poa_outdated'}) if $poa_status eq 'expired' and $client->risk_level_aml eq 'high';

        foreach my $mt5_account_id (@mt5_accounts) {
            my $mt5_account = $loginid_details{$mt5_account_id};
            return 1 if not defined $mt5_account->{status} and $poa_status eq 'verified';

            return 1 if ($mt5_account->{status} // 'active') eq 'poa_outdated' && !$client->is_high_risk;

            # look back for authentication updates (might have been outdated, etc)
            my $mt5_creation_datetime = Date::Utility->new($mt5_account->{creation_stamp});
            my $days_elapsed          = $current_datetime->days_between($mt5_creation_datetime);
            my $poa_failed_by_expiry  = $days_elapsed <= $grace_period ? 0 : 1;
            $self->fail($error_message, params => {mt5_status => 'poa_failed'}) if $poa_failed_by_expiry;
        }

        my $poi_status = $client->get_poi_status_jurisdiction({landing_company => $mt5_jurisdiction});
        $self->fail($error_message, params => {mt5_status => 'poa_pending'}) if $poi_status eq 'verified';

        return 1;
    },
};

rule 'mt5_account.account_proof_status_allowed' => {
    description => 'Checks if mt5 account are considered valid by poi and poa',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client              = $context->client($args);
        my $mt5_jurisdiction    = $args->{mt5_jurisdiction};
        my $mt5_id              = $args->{mt5_id};                                                       # mt5_id will overwrite the mt5_jurisdiction
        my %loginid_details     = %{$args->{loginid_details}};
        my $error_message       = 'ProofRequirementError';
        my $jurisdiction_config = BOM::Config::TradingPlatform::Jurisdiction->new();
        my @jurisdictions_list  = $jurisdiction_config->get_verification_required_jurisdiction_list();

        die 'If mt5_id is provided, mt5_jurisdiction should not be provided' if defined $mt5_id and defined $mt5_jurisdiction;

        my %proof_check = (
            poi => sub {
                $client->get_poi_status_jurisdiction({landing_company => shift});
            },
            poa => sub {
                $client->get_poa_status();
            },
        );

        if (defined $mt5_id and exists $loginid_details{$mt5_id}) {
            return 1 if ($loginid_details{$mt5_id}->{account_type} // '') eq 'demo';
            return 1 unless defined $loginid_details{$mt5_id}->{attributes}->{group};
            my $jurisdictions_regex = join('|', @jurisdictions_list);
            ($mt5_jurisdiction) = $loginid_details{$mt5_id}->{attributes}->{group} =~ m/($jurisdictions_regex)/g;
        }

        my @proof_requirements;
        @proof_requirements = $jurisdiction_config->get_jurisdiction_proof_requirement($mt5_jurisdiction) if defined $mt5_jurisdiction;
        return 1 unless @proof_requirements;

        # Status to consider - verification_pending, verified, poa_failed.

        my %proof_status = map { $_ => {$proof_check{$_}->($mt5_jurisdiction) => 1} } @proof_requirements;

        #Here checking whether we require authentication only first deposit by the client or not(In this case only for Maltainvest clients as part of DIEL flow)
        if ($client->landing_company->first_deposit_auth_check_required) {
            if (all { _is_proof_needed($proof_status{$_}) } @proof_requirements) {
                if (any { $proof_status{$_}->{none} } @proof_requirements) {
                    $self->fail($error_message, params => {mt5_status => 'needs_verification'});
                } elsif (any { $proof_status{$_}->{pending} } @proof_requirements) {
                    $self->fail($error_message, params => {mt5_status => 'verification_pending'});
                }
            }

        }

        $self->fail($error_message, params => {mt5_status => 'proof_failed'}) if any { _is_proof_failed($proof_status{$_}) } @proof_requirements;

        $self->fail($error_message, params => {mt5_status => 'verification_pending'})
            if any { ($proof_status{$_}->{pending} // 0) == 1 } @proof_requirements;

        return 1;
    }
};

=head2 _is_proof_failed

Check if current proof status considered failed. Anything other than 'verified' or 'pending' considered failed.

=over 4

=item * C<proof_status> - The current poi/poa's verification result.

=back

=cut

sub _is_proof_failed {
    my $proof_status = shift;
    return 0 if any { ($proof_status->{$_} // 0) == 1 } ('verified', 'pending');
    return 1;
}

=head2 _is_proof_needed

Check if current proof status considered pending or needs_verification. It should return 1 if any of the proof status is 'verified' or 'pending'.

=over 4

=item * C<proof_status> - The current poi/poa's verification result.

=back

=cut

sub _is_proof_needed {
    my $proof_status = shift;
    return 1 if any { ($proof_status->{$_} // 0) == 1 } ('verified', 'pending', 'none');
    return 0;
}

