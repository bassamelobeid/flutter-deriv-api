package BOM::Database::Model::EPG;

use Moose;
use Data::UUID;

has 'client' => (
    is       => 'ro',
    required => 1,
);

has 'dbh' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbh {
    return (shift)->client->db->dbh;
}

sub prepare {
    my $self = shift;
    my %params = @_ % 2 ? %{$_[0]} : @_;

    my $client = $self->client;
    my $account = $client->default_account || die "no account";

    my $id = Data::UUID->new()->create_str();
    $id =~ s/\-//g;

    $self->dbh->do("
        INSERT INTO payment.epg_request
            (id, amount, payment_type_code, status, account_id, payment_currency, payment_country, ip_address)
        VALUES
            (?, ?, ?, ?, ?, ?, ?, ?)
    ", undef,
        $id, $params{amount}, $params{payment_type_code},
        'PENDING',
        $account->id,
        $account->currency_code,
        uc($client->residence // ''),
        $params{ip_address} || '',
    );

    return $id;
}

sub complete {
    my ($self, @success_data) = @_;

    return 0 if @success_data > 1;    # require a FIX

    my $data          = $success_data[0];
    my $id            = $data->{id};
    my ($epg_request) = $self->dbh->selectrow_hashref("
        SELECT * FROM payment.epg_request WHERE id = ?
    ", undef, $id);

    return 0 unless $epg_request;

    # compare currency and amount
    if ($data->{amount} != $epg_request->{amount}) {
        $self->dbh->do("
            UPDATE payment.epg_request SET status = ?, remark = ? WHERE id = ?
        ", undef, 'AMOUNT_NOT_MATCH', $data->{data}, $id);
        return 0;
    }
    if ($data->{currency} ne $epg_request->{payment_currency}) {
        $self->dbh->do("
            UPDATE payment.epg_request SET status = ?, remark = ? WHERE id = ?
        ", undef, 'CURRENCY_NOT_MATCH', $data->{data}, $id);
        return 0;
    }

    my $client = $self->client;
    my $account = $client->default_account || die "no account";
    if ($account->id != $epg_request->{account_id}) {
        $self->dbh->do("
            UPDATE payment.epg_request SET status = ?, remark = ? WHERE id = ?
        ", undef, 'ACCOUNT_NOT_MATCH', $account->id, $id);
        return 0;
    }

    my $amount       = $data->{amount};
    my %payment_args = (
        currency          => $data->{currency},
        amount            => $amount,
        remark            => substr($data->{data}, 0, 800),    # b/c payment table remark is character varying(800)
        staff             => $client->loginid,
        created_by        => '',
        trace_id          => 0,
        payment_processor => $data->{paymentSolution},
        # transaction_id    => $transaction_id,
        ip_address => $epg_request->{ip_address},
    );

    my $fee = 0;                                               # FIXME

    # Write the payment transaction
    my $trx;

    if ($data->{type} eq 'deposit') {
        $trx = $client->payment_epg(%payment_args);
    } elsif ($data->{type} eq 'withdrawal') {
        # Don't allow balances to ever go negative! Include any fee in this test.
        my $balance = $client->default_account->load->balance;
        if ($amount + $fee > $balance) {
            my $plusfee = $fee ? " plus fee $fee" : '';
            return 0;
            # "Requested withdrawal amount $currency_code $amount$plusfee exceeds client balance $currency_code $balance"
        }
        $trx = $client->payment_epg(%payment_args, amount => sprintf("%0.2f", -$amount));
    }

    $self->dbh->do("
        UPDATE payment.epg_request SET status = ?, remark = ?, transaction_id = ? WHERE id = ?
    ", undef, 'OK', $data->{data}, $trx->id, $id);

    return $trx->id;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
