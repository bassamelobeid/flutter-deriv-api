package BOM::Database::DataMapper::AccountBase;

use Moose;
use BOM::Database::Model::Account;
extends 'BOM::Database::DataMapper::Base';

has 'account' => (
    is        => 'rw',
    isa       => 'Maybe[BOM::Database::Model::Account]',
    predicate => 'is_account_initializied',
    lazy      => 1,
    builder   => '_build_account',
);

sub _build_account {
    my $self = shift;

    my $account = BOM::Database::Model::Account->new({
            'data_object_params' => {
                'client_loginid' => $self->client_loginid,
                'currency_code'  => $self->currency_code
            },
            db => $self->db,
        });

    $account->load({'load_params' => {speculative => 1}});

    return $account;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=pod

=head1 NAME

BOM::Database::DataMapper::AccountBase

=head1 VERSION

0.1

=head1 AUTHOR

RMG Company

=cut
