package BOM::Database::Model::EPG;

use Moose;
use Data::UUID;

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

    my $id = Data::UUID->new()->create_str();

    $self->dbh->do("
        INSERT INTO payment.epg_request
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

no Moose;
__PACKAGE__->meta->make_immutable;

1;
