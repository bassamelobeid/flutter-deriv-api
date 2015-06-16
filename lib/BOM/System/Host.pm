package BOM::System::Host;

use Moose;
use namespace::autoclean;
use Moose::Util::TypeConstraints;
use MooseX::StrictConstructor;
use MooseX::Types::Moose qw( Int Str );
use BOM::System::Types qw( bom_ipv4_host_address );
use Sys::Hostname qw();

=head1 NAME

BOM::System::Host

=head1 SYNOPSYS

    my $server = BOM::System::Host->new(
        name           => 'cr-deal01',
        domain         => 'regentmarkets.com',
        canonical_name => 'crservers-cr-deal01',
        ip_address     => '190.241.168.35',
        groups         => [ 'rmg' ],
        roles          => [ BOM::System::Host::Role::Registry->get('customer_facing_webserver') ],
    );

=head1 DESCRIPTION

This class represents a single network host (which could be a server, a router, a printer, or anything).

=head1 ATTRIBUTES

=cut

=head2 name

name of the server. e.g. collector01

=cut

has name => (
    is       => 'ro',
    required => 1,
);

=head2 canonical_name

canonical name, by default the same as I<name>. E.g. tierpoint-collector01.

=cut

has canonical_name => (
    is      => 'ro',
    lazy    => 1,
    default => sub { shift->name },
);

=head2 ip_address

The public IP address for this server.

=cut

has ip_address => (
    is       => 'ro',
    isa      => 'bom_ipv4_host_address',
    required => 1,
);

=head2 domain

The internal domain name. E.g. regentmarkets.com
This is used for machines to talk to each other,
the address listed here should not be published
to the internet.

This allows us to sit behind protective/cdn proxies
like cloudflare while still allowing our services to
communicate bypassing the proxies

=cut

has domain => (
    is      => 'ro',
    default => 'regentmarkets.com',
);

=head2 domain

Externally reachable domain name. E.g. binary.com
This is the address reachable from the internet

=cut

has external_domain => (
    is      => 'ro',
    default => 'binary.com',
);

=head2 groups
The group(s) to which this host belongs.

=cut

has groups => (
    is      => 'rw',
    isa     => 'ArrayRef[Str]',
    default => sub { ['rmg'] },
);

=head2 roles

The role(s) played by this host.

=cut

has roles => (
    is      => 'rw',
    isa     => 'ArrayRef[BOM::System::Host::Role]',
    default => sub { [] },
);

=head2 host_type

A free-form field to describe the "type" of host that this is.

=cut

has host_type => (
    is      => 'ro',
    default => 'Unknown',
);

=head2 os_vendor

A free-form field to describe the OS vendor, e.g. 'Debian' or 'Microsoft'

=cut

has os_vendor => (
    is      => 'ro',
    default => 'Unknown',
);

=head2 os_name

A free-form field to describe the OS name, e.g. "Linux" or "Windows".

=cut

has os_name => (
    is      => 'ro',
    default => 'Unknown',
);

=head2 os_version

A free-form field to describe the OS version. By convention, please use the numerical
versions ("6.0") rather than cute names ("Squeeze") - it makes ordinal comparisons
more useful :-)

=cut

has os_version => (
    is      => 'ro',
    default => 'Unknown',
);

=head2 os_architecture

The processor chip architecture that the operating system runs on. This may be different
than the physical processor in the machine on which the host is running, due to virtualization.

=cut

has os_architecture => (
    is      => 'ro',
    default => 'Unknown',
);

=head2 virtualization_host

If set, the BOM::System::Host object that represents the virtualization server on which $self runs.

=cut

has virtualization_host => (is => 'rw');

=head2 aws_region

The Amazon Web Services (AWS) EC2 region in which this host is located.

NOTE: This field is relevant for Amazon EC2 instances only.

=cut

has 'aws_region' => (is => 'ro');

=head2 instance_type

The Amazon Web Services (AWS) EC2 instance type.

NOTE: This field is relevant for Amazon EC2 instances only.

=cut

has 'instance_type' => (is => 'ro');

=head2 storage_volume

Total hard disk space available in the server for storage.

=cut

has 'storage_volume' => (is => 'ro');

=head2 aws_account

The RMG account under which this EC2 instance is registered.

NOTE: This field is relevant for Amazon EC2 instances only.

=cut

has 'aws_account' => (
    is => 'ro',
);

=head2 ec2_security_group_name

The name of the Amazon EC2 security group associated with this host. Defaults to $self->fqdn.

NOTE: This field is relevant for Amazon EC2 instances only.

=cut

has ec2_security_group_name => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return $self->fqdn;
    });

=head2 pci_certification_id

For servers that have been PCI certified, the ID of the certification is stored here.

=cut

has pci_certification_id => (
    is  => 'ro',
    isa => Int,
);

=head2 birthdate

The date on which $self came into existence.

=cut

has birthdate => (
    is  => 'ro',
    isa => 'Str',
);

has 'role_definitions' => (
    is  => 'ro',
    isa => 'Maybe[BOM::System::Host::Role::Registry]',
);

=head2 Shared resources: num_cpu, RAM, disk

These attributes are typically defined for a virtualization host but not for virtual servers.

=cut

foreach my $field (qw(num_cpu RAM disk)) {
    __PACKAGE__->meta->add_attribute(
        $field,
        {
            is      => 'ro',
            lazy    => 1,
            default => sub {
                my $self = shift;
                return $self->virtualization_host
                    ? $self->virtualization_host->$field
                    : undef;
            },
        });
}

=head2 Physical server attributes: brand, bandwidth, contract_terms, purchase_price, monthly_rental

These attributes are typically defined for a virtualization host but not for virtual servers.

=cut

has [qw(brand bandwidth contract_terms purchase_price monthly_rental)] => (is => 'ro');

=head2 postgres_binary_replication_master

The name of the server, if any, that this server wants to replicate its postgres DB from.

Needless to say, this setting is only meaningful for Postgres binary replica servers.

=cut

has postgres_binary_replication_master => (
    is  => 'rw',
    isa => 'Str',
);

=head1 METHODS

=head2 $self->fqdn

Return full internal domain name for this server. E.g. collector01.regentmarkets.com
For difference between I<fqdn> and I<external_fqdn> check I<domain> and I<external_domain>

=cut

sub fqdn {
    my $self = shift;
    return $self->name . '.' . $self->domain;
}

=head2 $self->external_fqdn

Return full external domain name for this server. E.g. collector01.binary.com
For difference between I<fqdn> and I<external_fqdn> check I<domain> and I<external_domain>

=cut

sub external_fqdn {
    my $self = shift;
    return $self->name . '.' . $self->external_domain;
}

=head2 is_collector

Is this a collector (also known as Master Live Server)?

=cut

sub is_collector {
    my $self = shift;
    return $self->has_role('master_live_server') ? 1 : 0;
}

=head2 $self->has_role($role)

Returns true if $self->roles contains $role, undef otherwise. See C<BOM::System::Host::Role>.

=cut

sub has_role {
    my $self  = shift;
    my $role  = shift;
    my @roles = (grep { $_->has_role($role) } (@{$self->roles}));
    return @roles ? 1 : undef;    # Coding to the coverage tool here
}

=head2 $self->belongs_to($group)

Returns true if $group is in the list of $self's groups, undef otherwise.

=cut

sub belongs_to {
    my $self  = shift;
    my $group = shift;
    return (grep { $_ eq $group } @{$self->groups}) ? 1 : undef;
}

=head2 BUILDARGS

As necessary, this method converts:

- 'localhost' name into the actual name of the local host
- named roles into BOM::System::Host::Role objects

=cut

sub BUILDARGS {
    my $self    = shift;
    my $arg_ref = shift;

    if ($arg_ref->{name} and $arg_ref->{name} eq 'localhost') {
        my @name = split(/\./, Sys::Hostname::hostname);
        $arg_ref->{name} = $arg_ref->{canonical_name} = $name[0];
    }

    my $role_definitions = $arg_ref->{role_definitions};
    my $actual_roles     = [];
    if ($role_definitions) {
        foreach my $role (@{$arg_ref->{roles}}) {
            if (not ref $role) {
                my $obj = $role_definitions->get($role);
                if ($obj) {
                    push @$actual_roles, $obj;
                } else {
                    Carp::croak("Unknown BOM::System::Host::Role $role");
                }
            } else {
                push @$actual_roles, $role;
            }
        }
    }
    $arg_ref->{roles} = $actual_roles;

    return $arg_ref;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Nick Marden, C<< <nick at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut

