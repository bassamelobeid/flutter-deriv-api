package BOM::Database::Helper::RejectedTrade;

use Moose;
use Rose::DB;
use JSON::XS ();
use Carp;

has 'id' => (
    is => 'rw',
);

has 'login_id' => (
    is => 'rw',
);

has 'financial_market_bet_id' => (
    is => 'rw',
);

has 'shortcode' => (
    is => 'rw',
);

has 'action_type' => (
    is => 'rw',
);

has 'reason' => (
    is => 'rw',
);

has 'details' => (
    is => 'rw',
);

has 'db' => (
    is  => 'rw',
    isa => 'Rose::DB',
);

sub record_fail_txn {
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
