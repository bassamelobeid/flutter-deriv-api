package BOM::Database::DataMapper::PaymentAgent;

=head1 NAME

BOM::Database::DataMapper::PaymentAgent

=head1 DESCRIPTION

This is a class that will collect queries for payment agents

=head1 VERSION

0.1

=cut

use Moose;
use Date::Utility;
extends 'BOM::Database::DataMapper::AccountBase';

=head1 METHODS

=over

=item get_authenticated_payment_agents

get all authenticated payment agent

=back

=cut

sub get_authenticated_payment_agents {
    my ($self, %args) = @_;
    my ($target_country, $currency_code, $is_listed) = @args{qw/target_country currency_code is_listed/};

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $authenticated_pa_sth = $_->prepare('SELECT * FROM betonmarkets.get_payment_agents_by_country(?, ?, ?, ?)');
            $authenticated_pa_sth->execute($target_country, 't', $currency_code, $is_listed);

            return $authenticated_pa_sth->fetchall_hashref('client_loginid');
        });
}

=head1 METHODS

=over

=item get_all_authenticated_payment_agent_countries

get all authenticated payment agent countries

=cut

sub get_all_authenticated_payment_agent_countries {
    my $self = shift;

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $authenticated_payment_agents_statement = $_->prepare('SELECT country FROM betonmarkets.get_payment_agents_countries(?)');

            $authenticated_payment_agents_statement->execute('t');

            if ($authenticated_payment_agents_statement->execute()) {
                return $authenticated_payment_agents_statement->fetchall_arrayref;
            }
        });
}

=over

=item get_payment_agents_linked_to_client

Returns the loginids of payment agents with any transfer/deposit/withdrawal to/from the client represented by the input loginid.

=cut

sub get_payment_agents_linked_to_client {
    my ($self, $loginid) = @_;

    return $self->db->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref('SELECT * FROM betonmarkets.get_payment_agents_linked_to_client(?)', undef, $loginid);
        });
}

no Moose;
__PACKAGE__->meta->make_immutable;

=back

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2014 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
