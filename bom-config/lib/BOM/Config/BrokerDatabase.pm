package BOM::Config::BrokerDatabase;

use strict;
use warnings;
no indirect ':fatal';

use Array::Utils qw(array_minus);
use LandingCompany::Registry;

my %broker_config;

=head2 load_data

Loads and validates broker database data. Returns the loaded data as a hash-ref.

=cut

sub load_data {
    my $config = BOM::Config::broker_databases();

    my @config_brokers = keys %$config;
    my @valid_brokers  = LandingCompany::Registry->all_broker_codes();

    my @extra_brokers = array_minus(@config_brokers, @valid_brokers);
    die 'Invalid brokers found in database domain config: ' . join(',', @extra_brokers) if @extra_brokers;

    @extra_brokers = array_minus(@valid_brokers, @config_brokers);
    die 'Some brokers are left without any database domain config: ' . join(',', @extra_brokers) if @extra_brokers;

    %broker_config = %$config;
}

BEGIN {
    load_data();
}

=head2 get_domain

Finds the database domain name for a borker code. It takes the following args:

=over 4

=item * C<broker>: broker code

=back

=cut

sub get_domain {
    my (undef, $broker) = @_;

    die 'Broker code is missing' unless $broker;

    return %broker_config{$broker};
}

1;
