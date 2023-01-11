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
use List::Util qw( any );

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

        my $poa_status = $client->get_poa_status();
        return 1 if $poa_status eq 'verified';

        if (defined $mt5_jurisdiction) {
            return 1 unless exists JURISDICTION_DAYS_LIMIT()->{$mt5_jurisdiction};
        } else {
            return 1;
        }

        if (defined $mt5_id) {
            my $selected_mt5_status = $loginid_details{$mt5_id}->{status} // 'active';
            $self->fail($error_message) if $selected_mt5_status eq 'poa_failed';
            return 1 unless any { $selected_mt5_status eq $_ } qw/poa_pending poa_rejected proof_failed verification_pending/;
        }

        my @mt5_accounts =
            grep {
                    ($loginid_details{$_}->{platform} // '') eq 'mt5'
                and $loginid_details{$_}->{account_type} eq 'real'
                and $loginid_details{$_}->{attributes}->{group} =~ m/$mt5_jurisdiction/
            } keys %loginid_details;

        my $current_datetime = Date::Utility->new(Date::Utility->new->datetime);
        if (defined $mt5_id and exists $loginid_details{$mt5_id}) {
            return 1 unless defined $loginid_details{$mt5_id}->{attributes}->{group};
            ($mt5_jurisdiction) = $loginid_details{$mt5_id}->{attributes}->{group} =~ m/(bvi|vanuatu)/g;
        }

        foreach my $mt5_account_id (@mt5_accounts) {
            my $mt5_account = $loginid_details{$mt5_account_id};
            return 1 if not defined $mt5_account->{status};
            my $mt5_creation_datetime = Date::Utility->new($mt5_account->{creation_stamp});
            my $days_elapsed          = $current_datetime->days_between($mt5_creation_datetime);
            my $poa_failed_by_expiry  = $days_elapsed <= JURISDICTION_DAYS_LIMIT()->{$mt5_jurisdiction} ? 0 : 1;
            $self->fail($error_message, params => {mt5_status => 'poa_failed'}) if $poa_failed_by_expiry;
        }

        my $poi_status = $client->get_poi_status_jurisdiction($mt5_jurisdiction);
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

        my %proof_check = (
            poi => sub {
                $client->get_poi_status_jurisdiction(shift);
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

        $self->fail($error_message, params => {mt5_status => 'proof_failed'}) if any { _is_proof_failed($proof_status{$_}) } @{$required_proof};

        $self->fail($error_message, params => {mt5_status => 'verification_pending'})
            if any { ($proof_status{$_}->{pending} // 0) == 1 } @{$required_proof};

        return 1;
    },
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
