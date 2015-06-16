package BOM::Platform::CustomClientLimits;

=head1 DESCRIPTION

BOM::Platform::CustomClientLimits

Customer-specific turnover limits against known exploitable conditions.

=cut

use Moose;
use Carp qw(confess);
use List::MoreUtils qw(notall);

use BOM::Platform::Runtime;
use Date::Utility;

=head2 full_list

Returns the full custom client limits in a hashref with loginid keys.

=cut

sub full_list {
    my $self = shift;

    return BOM::Platform::Runtime->instance->app_config->quants->internal->custom_client_limits;
}

=head2 watched

Does this client loginid have any custom limits applied?

=cut

sub watched {
    my ($self, $loginid) = @_;

    return $self->full_list->{$loginid};
}

=head2 client_limit_list

An arrayref of the current limits.

=cut

sub client_limit_list {
    my ($self, $loginid) = @_;

    my @limits;
    if (my $limits = $self->full_list->{$loginid}) {
        foreach my $market (sort keys %{$limits}) {
            foreach my $contract_kind (sort keys %{$limits->{$market}}) {
                my $stuff = $limits->{$market}->{$contract_kind};
                push @limits,
                    {
                    market        => $market,
                    contract_kind => $contract_kind,
                    comment       => $stuff->{comment},
                    payout_limit  => $stuff->{payout_limit},
                    staff         => $stuff->{staff},
                    modified      => $stuff->{modified},
                    };
            }
        }
    }

    return (@limits) ? \@limits : undef;
}

=head2 client_payout_limit_for_contract

Given a loginid and contract returns the payout limit

=cut

sub client_payout_limit_for_contract {
    my ($self, $loginid, $contract) = @_;

    my $limited;
    if ($loginid && $contract) {
        my @which = ('all');
        unshift @which, 'iv' unless $contract->is_atm_bet;
        while (not defined $limited and my $kind = shift @which) {
            $limited = $self->full_list->{$loginid}->{$contract->underlying->market->name}->{$kind}->{payout_limit};
        }
    }

    return $limited;
}

=head2 remove_loginid

Removes the given loginid from the custom client limits list

=cut

sub remove_loginid {
    my ($self, $loginid) = @_;
    my $current = $self->full_list;

    delete $current->{$loginid};

    BOM::Platform::Runtime->instance->app_config->quants->internal->custom_client_limits($current);
    return BOM::Platform::Runtime->instance->app_config->save_dynamic;
}

=head2 update

Add an entry to the watch list.  It is expected to be a hashref with
loginid, market, contract_kind, comment, staff and payout_limit keys.

=cut

sub update {
    my ($self, $supplied) = @_;

    # Apply a bare minimum of data hygiene
    my @required = qw(loginid market contract_kind payout_limit comment staff);
    if (notall { defined $supplied->{$_} } @required) {
        confess('Must supply a hashref with all required parameters: ' . join(',', @required));
    }

    my $current = $self->full_list;
    delete $supplied->{payout_limit}
        if ($supplied->{payout_limit} eq '');    # We use undef as a signal.
    my ($loginid, $market, $contract_kind, $payout_limit, $comment, $staff) =
        @{$supplied}{@required};

    if ($comment eq '') {

        # Remove an extant rule, if it exists and we removed the comment
        delete $current->{$loginid}->{$market}->{$contract_kind};

        # Then clean up our trail, if necessary.
        delete $current->{$loginid}->{$market}
            if (not scalar keys %{$current->{$loginid}->{$market}});
        delete $current->{$loginid}
            if (not scalar keys %{$current->{$loginid}});
    } else {
        # Add or replace the rule.
        $current->{$loginid}->{$market}->{$contract_kind} = {
            payout_limit => $payout_limit,
            comment      => $comment,
            staff        => $staff,
            modified     => Date::Utility->today->date_ddmmmyy,
        };
    }

    BOM::Platform::Runtime->instance->app_config->quants->internal->custom_client_limits($current);
    return BOM::Platform::Runtime->instance->app_config->save_dynamic;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
