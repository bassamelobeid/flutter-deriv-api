package BOM::User::Client::PaymentAgent;

use strict;
use warnings;

use BOM::User::Client;
use BOM::Database::DataMapper::PaymentAgent;
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
# There are 2 versions of client, One is BOM::Database::AutoGenerated::Rose::Client, which will be returned if we don't overwrite the sub client here.
# Another is the BOM::User::Client, which is a smarter one and is a subclass of the previous one. Here we overwrite this sub to return the smarter one.
# TODO: will fix it when we remove Rose:DB::Object
sub client {
    my $self = shift;
    return bless $self->SUPER::client, 'BOM::User::Client';
}

=head2 get_payment_agents

Will deliver the list of payment agents based on the provided country, currency and broker code.

Takes the following parameters:

=over 4

=item C<$country_code> - L<2-character ISO country code|https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2> to restrict search (agents with no country will not be included)

=item C<$broker_code> - Two letter representation of broker. For example CR.

=item C<$currency> - Three letter currency code. For example USD.

=back

Returns a  list of C<BOM::User::Client::PaymentAgent> objects.

=cut

sub get_payment_agents {
    my ($class, $country_code, $broker_code, $currency) = @_;
    die "Broker code should be specified" unless (defined($country_code) and defined($broker_code));
    my $query_args = {target_country => $country_code};
    $query_args->{currency_code} = $currency if $currency;
    my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => $broker_code});
    return $payment_agent_mapper->get_authenticated_payment_agents($query_args);
}
1;
