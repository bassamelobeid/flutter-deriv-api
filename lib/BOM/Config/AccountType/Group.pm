use Object::Pad;

class BOM::Config::AccountType::Group;

=head1 NAME

BOM::Config::AccountType::Group

=head1 DESCRIPTION

A class representing a an account group. Each group is defined by it's accessible services. Services
accesses are checked by C<can_serice_name> methods.

=cut

use List::Util qw(any uniq);
use BOM::Config;

# Services are identified simply by their names. The method 'supports_service' in
# BOM::Config::AccountType can be called in business logic codes (like rule engine and rpc) to check wether or not a service is supported.

use constant SERVICES => {
    map { $_ => 1 } (
        qw/trade link_to_accounts transfer_without_link p2p fiat_cashier crypto_cashier affiliate_commissions paymentagent_transfer paymentagent_withdraw/
    )};

=head1 METHODS -  accessors

=head2 name

Return the name of the account type group (role)

=cut

field $name : reader;

=head2 services

Returns the list of services available for the current group

=cut

field $services : reader;

=head2 services_lookup

An auxiliary lookup table that includes all services in the current group

Note: It's created for speeding up service lookups needed within internal methods.  It's recommended to use `I<supports_service>  for service lookup everywhere else.

=cut

field $services_lookup : reader;

=head2 supports_service

Checks if the account type supports a service.

=over 4

=item * C<$service>: service name. The list of services are available in L<BOM::Config::AccountType::Group::SERIVCES>.

=back

Returns 0 or 1.

=cut

method supports_service {
    my $service = shift;

    die 'Service name is missing' unless $service;

    return defined $services_lookup->{$service} ? 1 : 0;
}

=head2 new

Class constructor.

Takes the following parameters:

=over 4

=item * C<name> - a string that represent group name 

=item * C<services> - an array ref of the services accessible for the group

=back

=cut

BUILD {
    my %args = @_;

    $name = $args{name};
    die "Group name is missing" unless $name;

    if (my @invalid = grep { !SERVICES->{$_} } $args{services}->@*) {
        die "Invalid services found in group $args{name}: " . join(',', @invalid);
    }

    $services = [uniq $args{services}->@*];

    $services_lookup = +{map { $_ => 1 } @$services};
}

1;
