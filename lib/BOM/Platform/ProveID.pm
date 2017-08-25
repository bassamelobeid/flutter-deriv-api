package BOM::Platform::ProveID;

use strict;
use warnings;

use BOM::Platform::Runtime;
use BOM::Platform::Config;
use BOM::Platform::RedisReplicated;
use base 'Experian::IDAuth';

=head1 NOTES

ProveID is for UK clients only. It checks the client against credit rating agencies. It checks his name, DOB, address.

If more than 2 items are found, the client is considered fully authenticated.

=cut

# override some of the defaults with our credentials, and our folder.
sub new {
    my ($class, %args) = @_;
    my $client = $args{client} || die 'needs a client';

    my $obj = bless {client => $client}, $class;
    $obj->set($obj->defaults, %args);
    return $obj;
}

sub _throttle {
    my $loginid = shift;
    my $key     = 'PROVEID::THROTTLE::' . $loginid;

    die 'Too many ProveID requests for ' . $loginid if BOM::Platform::RedisReplicated::redis_read()->get($key);

    BOM::Platform::RedisReplicated::redis_write()->set($key, 1, 'EX', 3600);

    return 1;
}

sub get_result {
    my $self = shift;
    _throttle($self->{client_id}) unless ($self->{force_recheck});
    return $self->SUPER::get_result();
}

sub defaults {
    my $self = shift;

    my $client = $self->{client};
    my $broker = $client->broker;
    my $db     = BOM::Platform::Runtime->instance->app_config->system->directory->db;
    my $folder = "$db/f_accounts/$broker/192com_authentication";

    return (
        $self->SUPER::defaults,
        username      => BOM::Platform::Config::third_party->{proveid}->{username},
        password      => BOM::Platform::Config::third_party->{proveid}->{password},
        folder        => $folder,
        residence     => $client->residence,
        postcode      => $client->postcode || '',
        date_of_birth => $client->date_of_birth || '',
        first_name    => $client->first_name || '',
        last_name     => $client->last_name || '',
        phone         => $client->phone || '',
        email         => $client->email || '',
        client_id     => $client->loginid,
    );
}

1;
