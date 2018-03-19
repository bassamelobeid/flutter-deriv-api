package BOM::User::Client::PaymentAgent;

use strict;
use warnings;

use BOM::User::Client;

use base 'BOM::Database::AutoGenerated::Rose::PaymentAgent';

## VERSION

# By drawing on Client's constructor we first prove the
# client record exists and we also benefit from the
# broker-savvy db connection handling there.
sub new {
    my ($class, @args) = @_;
    my $client = BOM::User::Client->new(@args) || return undef;
    my $self   = $client->payment_agent        || return undef;
    return bless $self, $class;
}

# Save to default writable place, unless explicitly set by caller..
sub save {
    my ($self, %args) = @_;
    $self->set_db(delete($args{set_db}) || 'write');
    return $self->SUPER::save(%args);
}

# Promote my client pointer to the smarter version of client..
sub client {
    my $self = shift;
    return bless $self->SUPER::client, 'BOM::User::Client';
}

1;
