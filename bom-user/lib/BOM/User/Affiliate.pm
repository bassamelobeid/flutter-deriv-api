package BOM::User::Affiliate;

use strict;
use warnings;

use parent 'BOM::User::Client';

=head2 new

Uses same arguments as BOM::User::Client.

Example usage:

    BOM::User::Affiliate->new({loginid => 'CRA000001'});

=cut

sub new {
    my $self = shift->SUPER::new(@_) // return;

    die 'Broker code ' . $self->broker_code . ' is not an affiliate broker code'
        unless BOM::User::Client->get_class_by_broker_code($self->broker_code // '') eq 'BOM::User::Affiliate';

    return $self;
}

=head2 landing_company

Returns the landing company config.

=cut

sub landing_company {
    my $self = shift;
    my $lc   = LandingCompany::Registry->by_broker($self->broker_code);

    die 'Broker code ' . $self->broker_code . ' is not an affiliate broker code' unless $lc->is_for_affiliates;

    return $lc;
}

=head2 is_wallet

Returns whether this client instance is a wallet.

=cut

sub is_wallet { 0 }

=head2 is_affiliate

Returns whether this client instance is an affiliate.

=cut

sub is_affiliate { 1 }

=head2 can_trade

Returns whether this client instance can perform trading.

=cut

sub can_trade { 0 }

=head2 set_affiliate_info

Saves specific affiliate info in to the database.

It takes the following data as hashref:

=over 4

=item * C<affiliate_plan> (mandatory) can be either 'turnover' or 'revenue_share'.

=back

Returns the current affiliate info.

=cut

sub set_affiliate_info {
    my ($self, $args) = @_;
    $self->set_db('write');

    $self->{info} = $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT * FROM betonmarkets.set_affiliate_info(?, ?)", undef, $self->loginid, $args->{affiliate_plan});
        });

    return $self->{info};
}

=head2 get_affiliate_info

Retrieves specific affiliates info from the database.

=cut

sub get_affiliate_info {
    my ($self) = @_;

    return $self->{info} //= $self->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT * FROM betonmarkets.get_affiliate_info(?)", undef, $self->loginid);
        });
}

1;
