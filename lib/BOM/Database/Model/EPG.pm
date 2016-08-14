package BOM::Database::Model::EPG;

use Moose;
use BOM::Database::AuthDB;

has 'client' => (is => 'ro', required => 1, isa => 'BOM::Platform::Client');

has 'dbh' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbh {
    return (shift)->client->db->dbh;
}

sub prepare_pending {
    my $self = shift;
    my %params = @_ % 2 ? %{$_[0]} : @_;

    my $client  = $self->client;
    my $account = $client->default_account || die "no account";

    my ($id) = $self->dbh->selectrow_array("SELECT nextval('sequences.payment_epg_serial')");

    $self->dbh->do("
        INSERT INTO payment.epg_pending
            (id, amount, payment_type_code, status, account_id, payment_currency, payment_country)
        VALUES
            (?, ?, ?, ?, ?, ?, ?)
    ", undef,
        $id, $params{amount}, $params{payment_type_code},
        'PENDING',
        $account->id,
        $account->currency_code,
        uc($client->residence // '')
    );

    return $id;
}

CREATE TABLE payment.epg_pending (
    id bigint DEFAULT nextval('sequences.payment_epg_serial'::regclass) NOT NULL,
    payment_time timestamp(0) without time zone DEFAULT now(),
    amount numeric(14,4) NOT NULL,
    payment_type_code character varying(50) NOT NULL,
    status character varying(20) NOT NULL,
    account_id bigint NOT NULL,
    payment_currency character varying(3) NOT NULL,
    payment_country character varying(12) NOT NULL,
    remark character varying(800) DEFAULT ''::character varying NOT NULL
);

no Moose;
__PACKAGE__->meta->make_immutable;

1;
