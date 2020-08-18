package BOM::MyAffiliates;

use strict;
use warnings;
use base 'WebService::MyAffiliates';
use BOM::Config;

use List::Util qw( first );
use Scalar::Util qw( looks_like_number );
use Carp;

## no critic (RequireArgUnpacking)

sub new {
    my $class = shift;
    my %args  = @_ % 2 ? %{$_[0]} : @_;

    $args{user} = BOM::Config::third_party()->{myaffiliates}->{user};
    $args{pass} = BOM::Config::third_party()->{myaffiliates}->{pass};
    $args{host} = BOM::Config::third_party()->{myaffiliates}->{host};

    return $class->SUPER::new(%args);
}

=over 4

=item get_default_plan

Given a MyAffiliates affiliate id, gives the default plan that the affiliate
is paid under.

If the affiliate is registered with more than one plan, it will default
to Revenue Share if present, and will never return Creative.

=cut

sub get_default_plan {
    my ($self, $affiliate_id) = @_;

    my $user_info         = $self->get_user($affiliate_id);
    my $subscriptions_ref = $user_info->{SUBSCRIPTIONS}->{SUBSCRIPTION};
    my @subscriptions     = (ref $subscriptions_ref eq 'HASH') ? ($subscriptions_ref) : @{$subscriptions_ref};

    my @plan_names = map { $_->{PLAN_NAME} } @subscriptions;

    return $plan_names[0] if scalar(@plan_names) == 1;

    # we prefer Revenue Share if present
    return 'Revenue Share' if first { $_ eq 'Revenue Share' } @plan_names;

    # weed out Creative as any plan should get priority over it
    @plan_names = grep { $_ ne 'Creative' } @plan_names;

    return $plan_names[0];
}

sub is_subordinate_affiliate {
    my ($self, $affiliate_id) = @_;

    my $user = $self->get_user($affiliate_id) or croak $self->errstr;

    my $affiliate_variables = $user->{USER_VARIABLES}->{VARIABLE};
    $affiliate_variables = [$affiliate_variables] unless ref($affiliate_variables) eq 'ARRAY';
    my ($subordinate_flag) = grep { $_->{NAME} eq 'subordinate' } @$affiliate_variables;
    return $subordinate_flag->{VALUE} if $subordinate_flag;
    return;
}

=item get_myaffiliates_id_for_promo_code

Given a BOM promo code, will check if there's an affiliate
associated with it and return their MyAffiliates affiliate id.

=cut

sub get_myaffiliates_id_for_promo_code {
    my ($self, $promocode) = @_;

    # To allow us to exactly match a promo code set in MyAffiliates, we had to
    # wrap the promo code strings in semi-colons (a character not used in promo
    # codes), then search for ";PROMO-CODE;". Otherwise, if one affiliate had
    # promo code FREECASH and another FREECASHNOW, a search for FREECASH would
    # match both, which is not what we want.
    # Also, to do partial searches we need to use the % wildcard, which on URLs
    # needs to be encoded as %25.
    return $self->_find_affiliate_by_variable('betonmarkets_promo_code' => "%;$promocode;%");
}

=item _find_affiliate_by_variable

 Call their Search API to find a user with a particular variable set.
 Use %25 as wildcard on the $value parameter

 Returns an affiliate id if exactly one id is found, false otherwise.

 eg.:
    exact match:
    _find_affiliate_by_variable('betonmarkets_client_loginid' => $bom_loginid);
    wildcard match for ;promocode;:
    _find_affiliate_by_variable('betonmarkets_promo_code' => "%25;$promocode;%25");

=cut

sub _find_affiliate_by_variable {
    my ($self, $variable_name, $value) = @_;

    my $user = $self->get_users(
        VARIABLE_NAME  => $variable_name,
        VARIABLE_VALUE => $value
    ) or croak $self->errstr;
    return unless $user->{USER};    # no matches

    # many matches
    croak 'Search returned more than one user' if ref($user->{USER}) eq "ARRAY";

    my $affiliate_id = $user->{USER}->{ID} || '';
    croak "ID is not a number? [id:$affiliate_id] while searching for variable [$variable_name => $value]" unless looks_like_number($affiliate_id);

    return $affiliate_id;
}

sub get_token {
    my ($self, $args_ref) = @_;

    my $affiliate_id = $args_ref->{affiliate_id} or croak 'Must pass affiliate_id to get_token';

    my $plan     = $args_ref->{plan} || $self->get_default_plan($affiliate_id) || '';
    my $setup_id = $plan ? $self->_get_setup_id($plan) : '';
    if (not $setup_id) {
        croak "Unable to get Setup ID for affiliate[$affiliate_id], plan[$plan]";
    }

    my $token_info = $self->encode_token(
        USER_ID  => $affiliate_id,
        SETUP_ID => $setup_id,
        ($args_ref->{media_id}) ? (MEDIA_ID => $args_ref->{media_id}) : (),
    ) or croak $self->errstr;

    my $token = $token_info->{USER}{TOKEN} or croak "Could not extract token from response.";
    return $token;
}

#
# When making a request to this API, we have to give two things:
# An affiliate ID (as identified in the MyAffiliates system, and called
# the USER_ID in the API) and
# a SETUP_ID, which is the id of a Link in the MyAffiliates system.
#
# There are cases when we want a token but have only the affiliate id,
# and would like a token that tells us that the Link (and everything
# else except the affiliate id) is unknown. The way we do this is to
# have an "unknown Link" ("unknown SETUP") in the MyAffiliates backend,
# and pass its id in the request by default.
#
sub _get_setup_id {
    my ($self, $plan_name) = @_;

    return unless $plan_name;

    my %plan_name_to_setup_id = (
        'Revenue Share' => 7,
        'Creative'      => 135,
        'Turnover'      => 136,
        'CPA'           => 137,
        'Deposit'       => 138,
        'No Payout'     => 139,
    );
    return $plan_name_to_setup_id{$plan_name};
}

=item fetch_account_transactions

Returns an array of "to Binary account" payment transactions
(HashRefs, with details of a transaction from the MyAffiliates system).

# MyAffiliates have four transaction types that you'll find against an
# affiliate's account:
#
# 1. Commission earned
#      Actual commission earned. Such a transaction will be credited to an affiliate
#      every month, no matter how small (and as long as their referrals' activity
#      results in them being owed commission of course).
#      These transactions are always CREDITED to the account it seems.
# 2. Payment out
#      When the affiliate accrues enough commission and breaks over minimum payment
#      threshold, a "payment to affiliate" transaction is added to the account.
#      This DEBITS from the account, and we are expected to then actually pay the
#      affiliate this amount.
#      So note: MyAffiliates do not wait for conformation that we paid the affiliate
#      or anything like that; they debit the payment first, and expect us to find
#      out what they should be paid, and pay them sucessfully.
# 3. Offset
#      Counteracts negative commission earned if business rules allow
#      (we don't do this).
# 4. Manual adjustment
#      If there's ever a need to manually adjust an account, the resulting
#      transaction will have this type.
#

=back
=cut

sub fetch_account_transactions {
    my $self = shift;
    my %args = @_ % 2 ? %{$_[0]} : @_;

    my $TRANSACTION_TYPE = $args{TRANSACTION_TYPE} || 2;

    my $transactions = $self->get_user_transactions(
        'TRANSACTION_TYPE' => $TRANSACTION_TYPE,
        'FROM_DATE'        => $args{FROM_DATE},
        'TO_DATE'          => $args{TO_DATE},
    );
    my $r = $transactions->{TRANSACTION};
    croak "No transactions found for $args{FROM_DATE} to $args{TO_DATE}" unless $r;
    my @all_transactions = (ref $r eq 'ARRAY') ? @$r : ($r);

    # Affiliates can have one of several different payment methods. One such
    # is "to a BOM account", the id of which in MyAffiliates is held as 7
    my @BOM_account_transactions;
    foreach my $transaction (@all_transactions) {
        if ($transaction->{USER_PAYMENT_TYPE}->{PAYMENT_TYPE_ID} == 7) {
            push @BOM_account_transactions, $transaction;
        }
    }

    return @BOM_account_transactions;
}

1;
