package BOM::Rules::RuleRepository::MT5;

=head1 NAME

BOM::Rules::RuleRepositry::MT5

=head1 DESCRIPTION

This modules declares rules and regulations pertaining the MT5.

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);
use Time::Moment;
use Date::Utility;
use List::Util qw( any all none );

use constant JURISDICTION_DAYS_LIMIT => {
    bvi     => 10,
    vanuatu => 5
};

use constant JURISDICTION_PROOF_REQUIREMENT => {
    bvi         => ['poi'],
    vanuatu     => ['poi'],
    labuan      => ['poi', 'poa'],
    maltainvest => ['poi', 'poa']};

rule 'mt5_account.account_poa_status_allowed' => {
    description => 'Checks if mt5 accounts are considered valid by poa status and jurisdiction',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);
        my $new_mt5_jurisdiction =
            $args->{new_mt5_jurisdiction};    # new_mt5_jurisdiction + loginid_details as parameter for new mt5 account (without an id)
        my $mt5_id           = $args->{mt5_id};               # mt5_id + loginid_details as parameter for existing mt5 account
        my %loginid_details  = %{$args->{loginid_details}};
        my $error_message    = 'POAVerificationFailed';
        my $mt5_jurisdiction = $new_mt5_jurisdiction;

        if (defined $mt5_id and exists $loginid_details{$mt5_id}) {
            return 1 unless defined $loginid_details{$mt5_id}->{attributes}->{group};
            ($mt5_jurisdiction) = $loginid_details{$mt5_id}->{attributes}->{group} =~ m/(bvi|vanuatu)/g;
        }

        my $poa_status = $client->get_poa_status(undef, $mt5_jurisdiction);
        return 1 if $poa_status eq 'verified';
        return 1
            if $poa_status eq 'expired'
            and $client->risk_level_aml ne 'high'
            and $client->fully_authenticated({landing_company => $mt5_jurisdiction});

        if (defined $mt5_jurisdiction) {
            return 1 unless exists JURISDICTION_DAYS_LIMIT()->{$mt5_jurisdiction};
        } else {
            return 1;
        }

        if (defined $mt5_id) {
            my $selected_mt5_status = $loginid_details{$mt5_id}->{status} // 'active';
            $self->fail($error_message) if $selected_mt5_status eq 'poa_failed';

            # active accounts might have to look back into the authentication status
            return 1
                unless any { $selected_mt5_status eq $_ }
                qw/poa_outdated poa_pending poa_rejected proof_failed verification_pending active needs_verification/;
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

            return 1 if ($mt5_account->{status} // 'active') eq 'poa_outdated' and $client->risk_level_aml ne 'high';

            # look back for authentication updates (might have been outdated, etc)
            my $mt5_creation_datetime = Date::Utility->new($mt5_account->{creation_stamp});
            my $days_elapsed          = $current_datetime->days_between($mt5_creation_datetime);
            my $poa_failed_by_expiry  = $days_elapsed <= JURISDICTION_DAYS_LIMIT()->{$mt5_jurisdiction} ? 0 : 1;
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
        my $client = $context->client($args);
        my $new_mt5_jurisdiction =
            $args->{new_mt5_jurisdiction};    # new_mt5_jurisdiction + loginid_details as parameter for new mt5 account (without an id)
        my $mt5_id           = $args->{mt5_id};               # mt5_id + loginid_details as parameter for existing mt5 account
        my %loginid_details  = %{$args->{loginid_details}};
        my $error_message    = 'ProofRequirementError';
        my $mt5_jurisdiction = $new_mt5_jurisdiction;
        my $mt5_new_acc      = $args->{new_mt5_account};

        my %proof_check = (
            poi => sub {
                $client->get_poi_status_jurisdiction({landing_company => shift});
            },
            poa => sub {
                $client->get_poa_status();
            },
        );

        if (defined $mt5_id and exists $loginid_details{$mt5_id}) {
            return 1 unless defined $loginid_details{$mt5_id}->{attributes}->{group};
            ($mt5_jurisdiction) = $loginid_details{$mt5_id}->{attributes}->{group} =~ m/(bvi|vanuatu|labuan|maltainvest)/g;
        }

        if (defined $mt5_jurisdiction) {
            return 1 unless exists JURISDICTION_PROOF_REQUIREMENT()->{$mt5_jurisdiction};
        } else {
            return 1;
        }

        my $required_proof = JURISDICTION_PROOF_REQUIREMENT()->{$mt5_jurisdiction};

        # Status to consider - verification_pending, verified, poa_failed.

        my %proof_status = map { $_ => {$proof_check{$_}->($mt5_jurisdiction) => 1} } @{$required_proof};

        #Here checking whether we require authentication only first deposit by the client or not(In this case only for Maltainvest clients as part of DIEL flow)
        if ($client->landing_company->first_deposit_auth_check_required) {
            $self->fail($error_message, params => {mt5_status => 'needs_verification'})
                if ($mt5_new_acc && $proof_status{'poi'}->{'none'} && $proof_status{'poa'}->{'none'});

            if (all { _is_proof_needed($proof_status{$_}) } @{$required_proof}) {
                if (any { $proof_status{$_}->{none} } @{$required_proof}) {
                    $self->fail($error_message, params => {mt5_status => 'needs_verification'});
                } elsif (any { $proof_status{$_}->{pending} } @{$required_proof}) {
                    $self->fail($error_message, params => {mt5_status => 'verification_pending'});
                }
            }

        }

        $self->fail($error_message, params => {mt5_status => 'proof_failed'}) if any { _is_proof_failed($proof_status{$_}) } @{$required_proof};

        $self->fail($error_message, params => {mt5_status => 'verification_pending'})
            if any { ($proof_status{$_}->{pending} // 0) == 1 } @{$required_proof};

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

