package BOM::User::Client::Account;

use strict;
use warnings;
use BOM::Database::AutoGenerated::Rose::Payment;
use BOM::Database::AutoGenerated::Rose::Transaction::Manager;
use BOM::User::Client::PaymentTransaction;
use BOM::Database::DataMapper::Payment;
use Date::Utility;
use JSON::MaybeXS ();
use Encode;
use Moo;

has 'id' => (
    is => 'ro',
);

has 'client_loginid' => (
    is => 'ro',
);

#Not used anymore but left for compatibility.
has 'is_default' => (
    is => 'ro',
);

#Rose::DB object
has 'db' => (
    is => 'ro',
);

my $json = JSON::MaybeXS->new;

=head2 BUILD

BUILD

When *C<new()> is called either retrieve an existing account from the DB or create one if required.

=cut

sub BUILD {
    my ($self, $args) = @_;

    my $db               = $args->{db};
    my $existing_account = $self->_refresh_object;
    return if $existing_account || !$args->{currency_code};

    # No current account but currency code supplied so we can create one
    my $result = $db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                "SELECT add_account as id FROM transaction.add_account(?,?)",
                undef,
                $args->{client_loginid},
                $args->{currency_code});
        });

    $self->{id}            = $result->{id};
    $self->{currency_code} = $args->{currency_code};

    return;
}

=head2 currency_code

This sub is used to set/get the currency associated with this account.

If no argument is provided it will behave as a get method.
If an argument is provided it will perform a set if there are no transactions
    associated with this account. This allows an accidental choice to be corrected
    without opening another account.
    The account currency will be returned whether or not a change was made.

=over 4

=item new_currency (optional) => string

=back

=cut

sub currency_code {
    my ($self, $new_currency) = @_;

    return $self->{currency_code} unless $new_currency;
    # Skip update if new currency is alike
    return $self->{currency_code} if $self->{currency_code} eq $new_currency;

    my $updated_currency = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_arrayref("SELECT transaction.set_account_currency(?,?)", undef, $self->id, $new_currency)->[0];
        });

    $self->{currency_code} = $updated_currency;

    return $self->{currency_code};
}

=head2 _refresh_object

Private method that refreshes the attributes of the  Account object from the database.


Takes no Arguments


Returns 1 or 0,  1 indicating that the object was found in the database.

=cut

sub _refresh_object {
    my $self             = shift;
    my $existing_account = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT * FROM transaction.account WHERE client_loginid = ? AND  is_default = TRUE",
                undef, $self->{client_loginid});
        });

    if (defined $existing_account) {
        @{$self}{keys %$existing_account} = values %$existing_account;
        return 1;
    }
    return 0;

}

=head2 balance

Returns the balance of the account the balance is set by a DB trigger
therefore we always read it from the DB fresh as it could be
out of date at any time.

=cut

sub balance {
    my $self = shift;
    $self->_refresh_object;
    return $self->{balance};
}

=head2 add_payment_transaction

Adds a payment to account, as well adding its corresponding transaction
to the transaction table. An optional second parameter adds a corresponding
row to the payment's child table, **assuming the child table has the same name
as payment_gateway_code**.

First parameter takes the following arguments as named parameters:

=over 4

=item account_id => bigint
=item amount => numeric
=item payment_gateway_code =>string
=item payment_type_code =>string
=item status => string
=item staff_loginid => string
=item remark =>string

=back

Second parameter takes a hash ref, where each key maps to a corresponding
column name in the payments child table.

Returns a PaymentTransaction object

=cut

sub add_payment_transaction {
    my $self                       = shift;
    my $payment_params             = shift;
    my $child_payment_table_params = shift;
    $payment_params->{account_id} = $self->id;

    my @bind_params = (
        @$payment_params{
            qw/account_id amount payment_gateway_code payment_type_code
                staff_loginid payment_time transaction_time status
                remark transfer_fees quantity source/
        },
        $child_payment_table_params ? Encode::encode_utf8($json->encode($child_payment_table_params)) : undef
    );

    my $txn = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT t.* from payment.add_payment_transaction(?,?,?,?,?,?,?,?,?,?,?,?,?) t", undef, @bind_params);
        });

    return BOM::User::Client::PaymentTransaction->new(%$txn);
}

=head2 total_withdrawals()

Finds the total amount of withdrawals, optionally from a specified period.

Takes the following arguments.

=over 4

=item L<Date::Utility>  (optional)  the time from when the amount of withdrawals should be calculated

=back

Returns a floating point number representing the total amount of withdrawals

=cut

sub total_withdrawals {
    my $self       = shift;
    my $start_time = shift;

    my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $self->client_loginid});
    return $payment_mapper->get_total_withdrawal({
        start_time => $start_time,
        exclude    => ['currency_conversion_transfer', 'account_transfer'],
    });

}

=head2 find_transaction

proxy for the autogenerated Rose account->find_transaction

Takes the same arguments as L<https://metacpan.org/pod/Rose::DB::Object::Manager>

the most interesting one is C<query> as below

=over 4

=item  C<query> an arrayref with keys and values to search on (see link above)

=back

   C<<$transactions = $account->find_transaction(query=>[id=>3]);>>

returns  an Array of Transaction Objects.

=cut

sub find_transaction {
    my ($self, %attrs) = @_;
    my $transactions = BOM::Database::AutoGenerated::Rose::Transaction::Manager->get_transaction(%attrs, db => $self->db);
    return $transactions;
}

=head2 find_financial_market_bet

proxy for the auto generated Rose account->find_financial_market_bet

Takes the same arguments as L<https://metacpan.org/pod/Rose::DB::Object::Manager>

the most interesting one is C<query> as below

=over 4

=item  C<query> an arrayref with keys and values to search on (see link above)

=back

   C<<$find_financial_market_best = $account->find_financial_market_bet(query=>[id=>3]);>>

returns an Array of FinancialMarketBet Objects.

=cut

sub find_financial_market_bet {
    my ($self, %attrs) = @_;
    push @{$attrs{query}}, ('account_id' => $self->id);
    my $financial_market_bets = BOM::Database::AutoGenerated::Rose::FinancialMarketBet::Manager->get_financial_market_bet(%attrs, db => $self->db);
    return $financial_market_bets;
}
1;
