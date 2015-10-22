package BOM::Platform::Runtime::Broker::Codes;

=head1 NAME

BOM::Platform::Runtime::Broker::Codes;

=head1 DESCRIPTION

Represents a set of all broker_codes within our system.
It primarily builds I<BOM::Platform::Runtime::Broker> objects from broker_codes.yml file and helps you query the set of objects.

=cut

use Moose;
use namespace::autoclean;
use BOM::Utility::Log4perl qw( get_logger );
use Carp;
use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Platform::Runtime::Broker;

=head1 METHODS

=head2 $self->get($code)

return L<BOM::Platform::Runtime::Broker> object for the specified broker

=cut

sub get {
    my ($self, $code) = @_;

    $code = $self->_loginid_or_broker_code_to_broker_code($code);
    croak "Unknown broker code or loginid [$code]" unless $self->_brokers->{$code};
    return $self->_brokers->{$code};
}

=head2 $self->all

Return list of all known brokers. Function returns L<BOM::Platform::Runtime::Broker> objects.

=cut

sub all {
    my $self = shift;
    return values %{$self->_brokers};
}

=head2 $self->all_codes

Return list of all known broker codes. Function returns Array of Strings.

=cut

sub all_codes {
    my $self = shift;
    return map { $_->code } values %{$self->_brokers};
}

=head2 $self->landing_company_for($broker_code|$client_loginid)

Return landing company (BOM::Platform::Runtime::LandingCompany) for given broker code or client login ID

=cut

sub landing_company_for {
    my $self = shift;
    my $code = shift;

    my $broker = $self->get($code);
    if ($broker) {
        return $broker->landing_company;
    } else {
        die "[landing_company_for] unknown broker code [$code]";
    }

    return;
}

=head2 $self->dealing_server_for($broker_code|$client_loginid)

Return dealing server (BOM::System::Runtime::Server) for given broker code or client login ID

=cut

sub dealing_server_for {
    my $self = shift;
    my $code = shift;

    my $broker = $self->get($code);
    if ($broker) {
        return $broker->server;
    }

    return;
}

has 'broker_definitions' => (
    is       => 'ro',
    required => 1,
);

has hosts => (
    is       => 'ro',
    weak_ref => 1,
    required => 1,
);

has landing_companies => (
    is       => 'ro',
    weak_ref => 1,
    required => 1,
);

has _brokers => (
    is         => 'ro',
    lazy_build => 1
);

has _brokers_on_servers => (
    is         => 'ro',
    lazy_build => 1
);

sub _build__brokers {
    my $self = shift;

    my $brokers = {};
    for my $broker_definition (@{$self->broker_definitions->{definitions}}) {
        my %args = map { $_ => $broker_definition->{$_} } grep { !/^code$/ } keys %$broker_definition;

        my $ref_broker = $broker_definition->{code}[0];
        $args{server} = $self->_valid_dealing_server($args{server}, $ref_broker);
        $args{landing_company} = $self->_valid_landing_company($args{landing_company}, $ref_broker);

        for my $code (@{$broker_definition->{code}}) {
            get_logger->logdie("Broker code $code specified twice in the configuration") if $brokers->{$code};
            $brokers->{$code} = BOM::Platform::Runtime::Broker->new(
                code => $code,
                %args
            );
        }
    }

    return $brokers;
}

sub _build__brokers_on_servers {
    my $self = shift;

    my $brokers_on_servers = {};
    foreach my $broker (values %{$self->_brokers}) {
        my $server = $broker->server->name;
        $brokers_on_servers->{$server} = [] unless ($brokers_on_servers->{$server});
        push @{$brokers_on_servers->{$server}}, $broker;
    }

    return $brokers_on_servers;
}

sub _valid_dealing_server {
    my $self       = shift;
    my $server     = shift;
    my $ref_broker = shift;

    my $dealing_server = $self->hosts->get($server);
    get_logger->logdie("Unknown server $server for broker ", $ref_broker) unless $dealing_server;

    return $dealing_server;
}

sub _valid_landing_company {
    my $self       = shift;
    my $lc_short   = shift;
    my $ref_broker = shift;

    my $lc = $self->landing_companies->get($lc_short);
    get_logger->logdie("Unknown landing company $lc_short for broker ", $ref_broker)
        unless $lc;

    return $lc;
}

# Examines a broker code or login ID and returns a best guess at the broker code associated with it. So, 'CR', 'CR1234', and 'CR4321' would all return 'CR'.

sub _loginid_or_broker_code_to_broker_code {
    my ($self, $code) = @_;

    return ($code =~ /^([A-Z]+)/) ? $1 : $code;
}

sub BUILD {
    my $self = shift;
    $self->all;
    return;
}

__PACKAGE__->meta->make_immutable;
1;

=head1 LICENSE AND COPYRIGHT

Copyright 2013 RMG Technology (M) Sdn Bhd

=cut
