package BOM::Database::DataMapper::MyAffiliates;

use Moose;
use BOM::Database::Model::Constants;

extends 'BOM::Database::DataMapper::Base';

=head1 METHODS

=over


=item get_clients_activity

get different factors of clients activity needed for myaffiliates pl reports.

=cut

sub get_clients_activity {
    my $self = shift;
    my $args = shift;
    my $dbic = $self->db->dbic;

    my $sql = q{
        SELECT * FROM get_myaffiliate_clients_activity($1)
    };

    return $dbic->run( fixup => 
        sub {
            my $sth = $_->prepare($sql);
            $sth->execute($args->{'date'}->datetime_yyyymmdd_hhmmss_TZ);

            return $sth->fetchall_hashref('loginid');
        });
}
no Moose;
__PACKAGE__->meta->make_immutable;

=back

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2010 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
