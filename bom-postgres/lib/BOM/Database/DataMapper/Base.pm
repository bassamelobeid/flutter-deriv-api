package BOM::Database::DataMapper::Base;

use Moose;

use BOM::Database::ClientDB;

has 'client_loginid' => (
    is      => 'rw',
    isa     => 'Maybe[Str]',
    default => undef,

);

has 'company_name' => (
    is      => 'rw',
    isa     => 'Maybe[Str]',
    default => undef,
);

has 'broker_code' => (
    is         => 'rw',
    isa        => 'Maybe[Str]',
    lazy_build => 1,
);

sub _build_broker_code {
    my $self = shift;
    return ($self->client_loginid =~ /^([A-Z]+)/) ? $1 : die 'no valid client_loginid [' . $self->client_loginid . ']';
}

has 'currency_code' => (
    is      => 'rw',
    isa     => 'Maybe[Str]',
    default => undef,
);

has 'operation' => (
    is      => 'rw',
    isa     => 'Str',
    default => 'write',
);

has 'db' => (
    is      => 'rw',
    isa     => 'Maybe[Rose::DB]',
    lazy    => 1,
    builder => '_build_db',
);

has 'debug' => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

has '_mapper_required_objects' => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    init_arg => undef,
    default  => sub { return [] },
);

sub _build_db {
    my $self = shift;

    my $build_params = {};

    $build_params->{'broker_code'} = $self->broker_code;
    $build_params->{'operation'}   = $self->operation;

    my $connection_builder = BOM::Database::ClientDB->new($build_params);

    return $connection_builder->db;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
