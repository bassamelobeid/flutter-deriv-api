package BOM::Platform::ProveID;

use strict;
use warnings;

use BOM::Utility::Log4perl;
use BOM::Platform::Runtime;
use BOM::System::Config;
use BOM::System::RedisReplicated;
use Carp;
use base 'Experian::IDAuth';

=head1 NOTES

ProveID is for UK clients only. It checks the client against credit rating agencies. It checks his name, DOB, address.

If more than 2 items are found, the client is considered fully authenticated.
We fall back to CheckID if it fails.

CheckID, for UK clients, will check against the electoral roll.
In other countries, it checks the drivers license, ID card number, passport MRZ.
But since we don't capture this data it won't work for us.
=cut

# override some of the defaults with our credentials, our logger, and our folder.
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

    if (BOM::System::RedisReplicated::redis_read()->get($key)) {
        Carp::confess 'Too many ProveID requests for ' . $loginid;
    }

    BOM::System::RedisReplicated::redis_write()->set($key, 1);
    BOM::System::RedisReplicated::redis_write()->expire($key, 3600);

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
        logger        => BOM::Utility::Log4perl::get_logger,
        username      => BOM::System::Config::third_party->{proveid}->{username},
        password      => BOM::System::Config::third_party->{proveid}->{password},
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
