package BOM::Database::ClientDB;

use Moose;
use feature "state";
use BOM::Database::Rose::DB;
use File::ShareDir;
use YAML::XS qw(LoadFile);
use JSON::XS;
use LandingCompany::Registry;

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

    # for some operations we use the collector that is aggregation of all db clusters
    if ($orig->{broker_code} and $orig->{broker_code} eq 'FOG') {
        $orig->{broker_code} = 'VRTC';
        $orig->{operation}   = 'collector';
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

my $environment;

BEGIN {
    my $loaded_landing_companies = LandingCompany::Registry::get_loaded_landing_companies();
    for my $v (values %$loaded_landing_companies) {
        $environment->{$_} = $v->{short} for @{$v->{broker_codes}};
    }
}

sub _build_db {
    my $self = shift;

    my $domain = $environment->{$self->broker_code};
    my $type   = $self->operation;

    my @db_params = (
        domain => $domain,
        type   => $type
    );

    my $db_postfix = $ENV{DB_POSTFIX} // '';
    if (not BOM::Database::Rose::DB->registry->entry_exists(@db_params)) {
        BOM::Database::Rose::DB->register_db(
            domain   => $domain,
            type     => $type,
            driver   => 'Pg',
            database => "$domain-$type$db_postfix",
            host     => '/var/run/postgresql',
            port     => 6432,
            username => 'write',
            password => '',
        );
    }

    return $self->_cached_db(@db_params);
}

sub _cached_db {
    my ($self, @db_params) = @_;

    my $db = BOM::Database::Rose::DB->db_cache->get_db(@db_params);

    unless ($db and $db->dbh and $db->dbh->ping) {
        $db = BOM::Database::Rose::DB->new(@db_params);
        BOM::Database::Rose::DB->db_cache->set_db($db);
    }

    return $db;
}
# this will help in calling functions in DB.
# result must be always rows of JSON
sub getall_arrayref {
    my $self = shift;
    my ($query, $params) = @_;

    my $sth = $self->db->dbh->prepare($query);
    $sth->execute(@{$params});

    my @result = map {JSON::XS::decode_json($_->[0])} @{$sth->fetchall_arrayref([0])};
    return \@result;
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;
