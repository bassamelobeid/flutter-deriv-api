package MyExp;
use strict; use warnings;
use base 'Experian::IDAuth';

=pod
sub new {
    my ($class, %args) = @_;
    my $client = $args{client} || die 'needs a client';

    my $obj = bless {client => $client}, $class;
    $obj->set($obj->defaults, %args);
    return $obj;
}
=cut

sub defaults {
    my $self = shift;

    my $client = $self->{client};
    my $folder = "/tmp/proveid";

    return (
        $self->SUPER::defaults,
        #logger        => BOM::Utility::Log4perl::get_logger,
        username      => 'search_facility',
        password      => 'B60SvDn9',
        folder        => $folder,
        residence     => 'gb',
        premise       => '10',
        postcode      => '066 8910',
        date_of_birth => '1971-10-09',
        first_name    => 'Julian',
        last_name     => 'Assange',
        phone         => '08329489',
        email         => '',
        client_id     => '1',
    );
}

1;
