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

        return 1 if $client->get_poa_status() eq 'verified';

        if (defined $mt5_jurisdiction) {
            return 1 unless exists JURISDICTION_DAYS_LIMIT()->{$mt5_jurisdiction};
        } else {
            return 1;
        }

        if (defined $mt5_id) {
            my $selected_mt5_status = $loginid_details{$mt5_id}->{status} // 'active';
            $self->fail($error_message, params => {failed_by_expiry => 0}) if $selected_mt5_status eq 'poa_failed';
            return 1 unless any { $selected_mt5_status eq $_ } qw/poa_pending poa_rejected/;
        }

        my @mt5_accounts =
            grep {
                    ($loginid_details{$_}->{platform} // '') eq 'mt5'
                and $loginid_details{$_}->{account_type} eq 'real'
                and $loginid_details{$_}->{attributes}->{group} =~ m/$mt5_jurisdiction/
            } keys %loginid_details;

        my $current_datetime = Date::Utility->new(Date::Utility->new->datetime);
        foreach my $mt5_account_id (@mt5_accounts) {
            my $mt5_account = $loginid_details{$mt5_account_id};
            return 1 if not defined $mt5_account->{status};
            my $mt5_creation_datetime = Date::Utility->new($mt5_account->{creation_stamp});
            my $days_elapsed          = $current_datetime->days_between($mt5_creation_datetime);
            my $poa_failed_by_expiry  = $days_elapsed <= JURISDICTION_DAYS_LIMIT()->{$mt5_jurisdiction} ? 0 : 1;
            $self->fail($error_message, params => {failed_by_expiry => 1}) if $poa_failed_by_expiry;
        }

        return 1;
    },
};
