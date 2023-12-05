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

=head2 get_all_authenticated_payment_agent_countries

Get all authenticated payment agent countries

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

=head2 get_payment_agents_linked_to_client

Returns the loginids of payment agents with any transfer/deposit/withdrawal to/from the client represented by the input loginid.

=cut

sub get_payment_agents_linked_to_client {
    my ($self, $loginid) = @_;

    return $self->db->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref('SELECT * FROM betonmarkets.get_payment_agents_linked_to_client(?)', undef, $loginid);
        });
}

=head2 get_payment_agents_details_full

Return a list of payment agents' full details each as a hashref based on the provided country and currency.

Takes the following parameters:

=over 4

=item * country_code - L<2-character ISO country code|https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2> to restrict search (agents with no country will not be included)

=item * currency - Three letter currency code. For example USD.

=item * is_listed - Indicate which payment agents you want to retrieve. whether they appear on binary site or not or both. For example ('t','f', NULL)

=item * details_fields_mapper - A hashref of the fields that need to be mapped. The key is the field name and the value is the field name of the linked details.

=back

=cut

sub get_payment_agents_details_full {
    my ($self, %args) = @_;

    my ($country_code, $currency, $is_listed, $details_field_mapper) = @args{qw/ country_code currency is_listed details_field_mapper/};

    if (!defined($country_code)) {
        die "country code should be specified";
    }

    my $db_rows = $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM betonmarkets.get_payment_agents_by_country_full(?, ?, ?, ?)',
                {Slice => {}},
                $country_code, 't', $currency, $is_listed
            );
        });

    if ($details_field_mapper) {
        $self->map_linked_details($db_rows, $details_field_mapper);
    }

    my %indexed_by_loginid = map { $_->{client_loginid} => $_ } $db_rows->@*;
    return \%indexed_by_loginid;
}

=head2 map_linked_details

Loop thorugh the db_rows and convert the array result of linked details to hashref based on the details_fields_mapper
Example map { urls => 'url'}
Db rows before
{urls => ['http://www.MyPAMyAdventure.com/','http://www.MyPAMyAdventure2.com/']}
Result {urls => [{url => 'http://www.MyPAMyAdventure.com/'},{url => 'http://www.MyPAMyAdventure2.com/'}]}

=over 4

=item C<$db_rows> - An array of hashref of the db rows which contains fields that need to be mapped

=item C<$details_field_mapper> - A hashref of the fields that need to be mapped. The key is the field name and the value is the field name of the linked details.

=back

=cut

sub map_linked_details {
    my ($self, $db_rows, $details_field_mapper) = @_;
    for my $row ($db_rows->@*) {
        for my $field (keys $details_field_mapper->%*) {
            $row->{$field} = [
                map {
                    { $details_field_mapper->{$field} => $_ }
                } $row->{$field}->@*
            ];
        }
    }
}

no Moose;
__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2014 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
