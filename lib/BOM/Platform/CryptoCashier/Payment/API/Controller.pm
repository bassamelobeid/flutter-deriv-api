package BOM::Platform::CryptoCashier::Payment::API::Controller;

use Mojo::Base 'Mojolicious::Controller';
use Format::Util::Numbers qw(financialrounding);
use Scalar::Util          qw(blessed);
use Syntax::Keyword::Try;
use Log::Any   qw($log);
use List::Util qw(first);

use BOM::Config::CurrencyConfig;
use BOM::Database::ClientDB;
use BOM::Platform::CryptoCashier::Payment::Error qw(create_error);
use BOM::Platform::Event::Emitter;
use BOM::Rules::Engine;
use BOM::User::Client;

=head2 deposit

A handler for the /v1/payment/deposit endpoint.
Credit the client account and return the payment_id on success.

=over 4

=item * C<$crypto_id>        - The crypto transaction reference id (Integer)

=item * C<$address>          - The deposit address hash (string)

=item * C<$amount>           - The transaction amount (float)

=item * C<$transaction_hash> - The blockchain transaction hash (string)

=item * C<$currency_code>    - The deposit payment currency code (string)

=item * C<$client_loginid>   - The client loginid (string)

=back

Returns 200 http code with error if the operation failed.
The success result contains the following keys:

=over 4

=item * C<payment_id> - The payment id in the client DB of the credit operation.

=back

=cut

sub deposit {
    my ($self) = @_;

    my $crypto_id        = $self->param('crypto_id') // return $self->render_error('MissingRequiredParameter', message_params => 'crypto_id');
    my $address          = $self->param('address')   // return $self->render_error('MissingRequiredParameter', message_params => 'address');
    my $amount           = $self->param('amount')    // return $self->render_error('MissingRequiredParameter', message_params => 'amount');
    my $transaction_hash = $self->param('transaction_hash')
        // return $self->render_error('MissingRequiredParameter', message_params => 'transaction_hash');
    my $currency_code = $self->param('currency_code') // return $self->render_error('MissingRequiredParameter', message_params => 'currency_code');
    my $client_loginid;

    return $self->render_error('MissingRequiredParameter', message_params => 'client_loginid')
        unless ($self->param('client_loginid') || $self->param('incorrect_loginid'));

    unless ($self->param('client_loginid')) {
        my $incorrect_loginid        = $self->param('incorrect_loginid');
        my $incorrect_loginid_client = BOM::User::Client->new({loginid => $incorrect_loginid});

        #TODO: Might need refactoring after releasing app store project(account type might change).
        my $sibling_accounts = $incorrect_loginid_client->get_siblings_information(
            include_disabled             => 0,
            include_virtual              => 0,
            exclude_disabled_no_currency => 1,
            include_self                 => 0
        );

        my $correct_account = first { $sibling_accounts->{$_}{currency} eq $currency_code } keys %$sibling_accounts;

        return $self->render_error('SiblingAccountNotFound', message_params => $crypto_id) unless ($correct_account);
        $client_loginid = $correct_account;
    } else {
        $client_loginid = $self->param('client_loginid');
    }

    # apply sensible rounding for the amount for credit
    $amount = financialrounding('amount', $currency_code, $amount);

    if (my $error = $self->init_payment_validation($currency_code, $client_loginid, $amount)) {
        return $self->render_error($error);
    }

    # first we check if we have proceed this transaction before
    # by getting the payment id from the client DB for this transaction
    my $payment_id = $self->get_payment_id_from_clientdb($client_loginid, $crypto_id, 'deposit');

    return $self->render_response({
            payment_id     => $payment_id,
            client_loginid => $client_loginid
        }) if $payment_id;

    my $fdp = $self->{client}->is_first_deposit_pending;

    my %payment_args = (
        currency         => $currency_code,
        amount           => $amount,
        remark           => $address,
        crypto_id        => $crypto_id,
        transaction_hash => $transaction_hash,
        address          => $address,
    );

    my $txn = $self->{client}->payment_ctc(%payment_args);

    return $self->render_error('FailedCredit', message_params => $crypto_id) unless $txn && $txn->{payment_id};

    BOM::Platform::Event::Emitter::emit(
        'payment_deposit',
        {
            loginid          => $self->{client}->loginid,
            is_first_deposit => $fdp,
            amount           => $payment_args{amount},
            currency         => $payment_args{currency},
            remark           => $payment_args{remark},
        });

    return $self->render_response({
        payment_id     => $txn->{payment_id},
        client_loginid => $client_loginid,
    });
}

=head2 withdraw

A handler for the /v1/payment/withdraw endpoint.
Debit the client account and return the payment_id on success.

=over 4

=item * C<$crypto_id>        - The crypto transaction reference id (Integer)

=item * C<$address>          - The deposit address hash (string)

=item * C<$amount>           - The transaction amount (float)

=item * C<$currency_code>    - The deposit payment currency code (string)

=item * C<$client_loginid>   - The client loginid (string)

=back

Returns 200 http code with error if the operation failed.
The success result contains the following keys:

=over 4

=item * C<payment_id> - The payment id in the client DB of the debit operation.

=back

=cut

sub withdraw {
    my ($self) = @_;

    my $crypto_id      = $self->param('crypto_id')      // return $self->render_error('MissingRequiredParameter', message_params => 'crypto_id');
    my $address        = $self->param('address')        // return $self->render_error('MissingRequiredParameter', message_params => 'address');
    my $amount         = $self->param('amount')         // return $self->render_error('MissingRequiredParameter', message_params => 'amount');
    my $currency_code  = $self->param('currency_code')  // return $self->render_error('MissingRequiredParameter', message_params => 'currency_code');
    my $client_loginid = $self->param('client_loginid') // return $self->render_error('MissingRequiredParameter', message_params => 'client_loginid');
    my $priority_fee   = $self->param('priority_fee')   // '';

    # apply sensible rounding for the amount for debit
    $amount = financialrounding('amount', $currency_code, $amount);

    if (my $error = $self->init_payment_validation($currency_code, $client_loginid, $amount)) {
        return $self->render_error($error);
    }

    # first we check if we have proceed this transaction before
    # by getting the payment id from the client DB for this transaction
    my $payment_id = $self->get_payment_id_from_clientdb($client_loginid, $crypto_id, 'withdrawal');

    return $self->render_response({
            payment_id => $payment_id,
        }) if $payment_id;

    # validate the payment first
    try {
        my $rule_engine = BOM::Rules::Engine->new(client => $self->{client});
        $self->{client}->validate_payment(
            currency     => $currency_code,
            amount       => -$amount,
            payment_type => 'crypto_cashier',
            rule_engine  => $rule_engine
        );
    } catch ($e) {
        my $error_message = $e->{message_to_client};
        return $self->render_error('InvalidPayment', message_params => $error_message);
    }

    my %payment_args = (
        currency         => $currency_code,
        amount           => -$amount,
        remark           => $address,
        crypto_id        => $crypto_id,
        transaction_hash => '',
        address          => $address,
        priority_fee     => $priority_fee
    );

    my $txn = $self->{client}->payment_ctc(%payment_args);

    return $self->render_error('FailedDebit', message_params => $crypto_id) unless $txn && $txn->{payment_id};

    return $self->render_response({
        payment_id => $txn->{payment_id},
    });
}

=head2 revert_withdrawal

A handler for the /v1/payment/revert_withdrawal endpoint.
Credit the client account back and return the payment_id on success.

=over 4

=item * C<$crypto_id>        - The crypto transaction reference id (Integer)

=item * C<$address>          - The deposit address hash (string)

=item * C<$amount>           - The transaction amount (float)

=item * C<$currency_code>    - The deposit payment currency code (string)

=item * C<$client_loginid>   - The client loginid (string)

=back

Returns 200 http code with error if the operation failed.
The success result contains the following keys:

=over 4

=item * C<payment_id> - The payment id in the client DB of the credit back operation.

=back

=cut

sub revert_withdrawal {
    my ($self) = @_;

    my $crypto_id      = $self->param('crypto_id')      // return $self->render_error('MissingRequiredParameter', message_params => 'crypto_id');
    my $address        = $self->param('address')        // return $self->render_error('MissingRequiredParameter', message_params => 'address');
    my $amount         = $self->param('amount')         // return $self->render_error('MissingRequiredParameter', message_params => 'amount');
    my $currency_code  = $self->param('currency_code')  // return $self->render_error('MissingRequiredParameter', message_params => 'currency_code');
    my $client_loginid = $self->param('client_loginid') // return $self->render_error('MissingRequiredParameter', message_params => 'client_loginid');

    # apply sensible rounding for the amount for credit
    $amount = financialrounding('amount', $currency_code, $amount);

    if (my $error = $self->init_payment_validation($currency_code, $client_loginid, $amount)) {
        return $self->render_error($error);
    }

    # first we should check if we have proceed this withdrawal transaction before
    # to get the payment id from the client DB for this transaction
    my $payment_id = $self->get_payment_id_from_clientdb($client_loginid, $crypto_id, 'withdrawal');
    return $self->render_error('MissingWithdrawalPayment', message_params => $crypto_id) unless $payment_id;

    # Second we should check if we have proceed this revert transaction before
    $payment_id = $self->get_payment_id_from_clientdb($client_loginid, $crypto_id, 'withdraw_revert');
    return $self->render_response({
            payment_id => $payment_id,
        }) if $payment_id;

    my %payment_args = (
        currency         => $currency_code,
        amount           => $amount,
        remark           => 'Withdrawal returned. Reference no.: ' . $crypto_id,
        crypto_id        => $crypto_id,
        transaction_hash => '',
        address          => $address,
        transaction_type => 'withdraw_revert',
    );

    my $txn = $self->{client}->payment_ctc(%payment_args);

    return $self->render_error('FailedRevert', message_params => $crypto_id) unless $txn && $txn->{payment_id};

    return $self->render_response({
        payment_id => $txn->{payment_id},
    });
}

=head2 init_payment_validation

Initial validation for the payment request

Takes the following parameters:

=over 4

=item * C<$currency_code>  - The currency code

=item * C<$client_loginid> - The client loginid

=item * C<$amount>         - The amount

=back

Returns the error structure if anything went wrong, otherwise C<undef>.

=cut

sub init_payment_validation {
    my ($self, $currency_code, $client_loginid, $amount) = @_;

    unless ($self->{client}) {
        $self->{client} = BOM::User::Client->new({loginid => $client_loginid});
    }

    return create_error('ClientNotFound', message_params => $client_loginid)
        unless (blessed $self->{client} && $self->{client}->isa('BOM::User::Client'));

    return create_error('InvalidCurrency', message_params => $currency_code)
        unless BOM::Config::CurrencyConfig::is_valid_crypto_currency($currency_code);

    return create_error('CurrencyNotMatch', message_params => $currency_code)
        unless $self->{client}->account->currency_code eq $currency_code;

    return create_error('ZeroPaymentAmount')
        unless $amount > 0;

    return;
}

=head2 get_payment_id_from_clientdb

Returns the payment_id from payment.ctc table based on the arguments we are passing.

=over 4

=item * C<client_loginid>   - The client's login id

=item * C<crypto_id>        - The DB row id of the transaction in crypto db

=item * C<transaction_type> - The transaction type (deposit/withdrawal)

=back

Returns payment_id if exists otherwise C<undef>.

=cut

sub get_payment_id_from_clientdb {
    my ($self, $client_loginid, $crypto_id, $transaction_type) = @_;

    my $client_dbic = BOM::Database::ClientDB->new({client_loginid => $client_loginid})->db->dbic;
    my $payment_id  = $client_dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT get_payment_id_from_payment_ctc FROM payment.get_payment_id_from_payment_ctc(?, ?)',
                undef, $crypto_id, $transaction_type);
        });

    return $payment_id;
}

=head2 invalid_request

Renders 404 status code

=cut

sub invalid_request {
    my $self = shift;

    return $self->render(
        text   => 'Invalid request.',
        status => 404
    );
}

=head2 render_response

Renders the response in JSON format and status code 200.

Takes the following parameters:

=over 4

=item * C<$response> - Response as hashref

=back

=cut

sub render_response {
    my ($self, $response) = @_;

    return $self->render(json => $response);
}

=head2 render_error

Renders the error in JSON format and status code 200.

Takes the following parameters:

=over 4

=item * C<$error> - The error code string or a hashref containing error information like C<code>, C<message>, etc.

=item * C<%params> - An optional hash containing the error parameters

=back

=cut

sub render_error {
    my ($self, $error, %params) = @_;

    $error = create_error($error, %params) unless ref $error;

    return $self->render_response({
        error => $error,
    });
}

1;
