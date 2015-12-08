package BOM::Database::ClientDB;

use Moose;
use feature "state";
use BOM::Database::Rose::DB;
use YAML::XS;

use Carp;

has broker_code => (
    is  => 'rw',
    isa => 'Str',
);

has operation => (
    is      => 'rw',
    isa     => 'Str',
    default => 'write',
);

has db => (
    is         => 'ro',
    isa        => 'Rose::DB',
    lazy_build => 1,
);

sub BUILDARGS {
    my $class = shift;
    my $orig  = shift;

    if (exists $orig->{operation} && $orig->{operation} !~ /^(write|collector|replica|backoffice_replica)$/) {
        croak "Invalid operation for DB " . $orig->{operation};
    }

    if (defined($orig->{broker_code})) {
        return $orig;
    }

    if (defined($orig->{client_loginid})) {
        if ($orig->{client_loginid} =~ /^([A-Z]+)\d+$/) {
            delete $orig->{client_loginid};
            $orig->{broker_code} = $1;
            return $orig;
        }
    }
    croak "At least one of broker_code, or client_loginid must be specified";
}

sub _build_db {
    my $self = shift;
    state $environment = +{
        map {
            my ($bcodes, $landing_company) = @{$_}{qw/code landing_company/};
            local $_;
            map {$_ => $landing_company} @$bcodes;
        } @{YAML::XS::LoadFile('/etc/rmg/broker_codes.yml')->{definitions}}
    };

    my $domain = $environment->{$self->broker_code};
    my $type   = $self->operation;

    my @db_params = (
        domain => $domain,
        type   => $type
    );

    if (not BOM::Database::Rose::DB->registry->entry_exists(@db_params)) {
        state $clientdb_config = YAML::XS::LoadFile('/etc/rmg/clientdb.yml');
        BOM::Database::Rose::DB->register_db(
            domain   => $domain,
            type     => $type,
            driver   => 'Pg',
            database => "$domain-$type",
            host     => '/var/run/postgresql',
            port     => 6432,
            username => 'write',
            password => '',
        );
    }

    return BOM::Database::Rose::DB->new(@db_params);
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;
