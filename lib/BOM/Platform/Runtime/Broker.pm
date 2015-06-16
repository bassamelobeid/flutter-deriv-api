package BOM::Platform::Runtime::Broker;

=head1 NAME

BOM::Platform::Runtime::Broker

=head1 SYNOPSYS

    my $cr = BOM::Platform::Runtime::Broker->new(
        code   => 'CR',
        server => 'server.for.cr.example.com',
        landing_company => $landing_company,
    );
    say "Server for ", $cr-code, " is ", $cr->server;

=head1 DESCRIPTION

This class represents brokers

=head1 ATTRIBUTES

=cut

use Moose;
use MooseX::StrictConstructor;
use namespace::autoclean;

=head2 code

Broker code (CR, VRTC, MX etc)

=cut

has code => (
    is       => 'ro',
    required => 1,
);

=head2 server

Dealing server for this broker

=cut

has server => (
    is       => 'ro',
    required => 1,
    default  => 'localhost',
);

=head2 landing_company

Landing company for this broker

=cut

has landing_company => (
    is       => 'ro',
    isa      => 'BOM::Platform::Runtime::LandingCompany',
    required => 1,
);

=head2 is_virtual

If this broker is virtual or not.

=cut

has is_virtual => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_is_virtual',
);

sub _build_is_virtual {
    my $self = shift;
    return $self->code =~ /^VRT/;
}

=head2 transaction_db_cluster

The db cluster this broker connects to.

=cut

has transaction_db_cluster => (
    is       => 'ro',
    required => 1,
);

__PACKAGE__->meta->make_immutable;

1;

=head1 LICENSE AND COPYRIGHT

Copyright 2010 RMG Technology (M) Sdn Bhd

=cut

