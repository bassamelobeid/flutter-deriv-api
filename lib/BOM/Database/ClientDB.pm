package BOM::Database::ClientDB;

use Carp;
use Moose;
use File::ShareDir;
use JSON::MaybeXS;
use Text::Trim qw(trim);
use LandingCompany::Registry;
use Syntax::Keyword::Try;
use YAML::XS qw(LoadFile);
use BOM::Config;

use BOM::Database::Rose::DB;

has broker_code => (
    is  => 'rw',
    isa => 'Str',
);

has loginid => (
    is  => 'rw',
    isa => 'Maybe[Str]',
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
    shift;
    my $orig = shift;

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
            $orig->{loginid}     = $orig->{client_loginid};
            $orig->{broker_code} = $1;
            delete $orig->{client_loginid};
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

=head2 _is_redirect_testcases_to_svg

This method checks whether in ci or qa testdb environement and not a collector

Returns true if the condition satisfied otherwise false

=cut

sub _is_redirect_testcases_to_svg {
    my $self = shift;

    my $db_postfix    = $ENV{DB_POSTFIX} // '';
    my $test_db_on_qa = (BOM::Config::on_qa() and $db_postfix eq '_test');
    my $test_on_ci    = BOM::Config::on_ci();

    return (($test_db_on_qa or $test_on_ci) and $self->{operation} ne 'collector');
}

sub _build_db {
    my $self   = shift;
    my $domain = $environment->{$self->broker_code};
    # We are relying on the wording of this message in other places. If you are
    # tempted to change anything here, please make sure to find those places and
    # change them as well.
    die "No such domain with the broker code " . $self->broker_code . "\n" unless $domain;

    my $db_postfix = $ENV{DB_POSTFIX} // '';

    # TODO: This part should not be around once we have unit_test cluster ~ JACK
    # redirect all of our client testcases to svg except for collector
    $domain = $self->_is_redirect_testcases_to_svg() ? 'svg' : $domain;

    my $type = $self->operation;

    my @db_params = (
        domain => $domain,
        type   => $type
    );

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

    if ($ENV{AUDIT_STAFF_NAME} and $ENV{AUDIT_STAFF_IP}) {
        $db->dbic->dbh->selectall_arrayref('SELECT audit.set_staff(?::TEXT, ?::CIDR)', undef, @ENV{qw/AUDIT_STAFF_NAME AUDIT_STAFF_IP/});
    }

    if ((BOM::Config->on_qa() or BOM::Config->on_ci())
        and $self->{operation} =~ /^(replica|backoffice_replica)$/)
    {
        # Currently in QA/CI environments, the database is setup such that user is able
        # to write to replicas. Until we can more accurately mimic production setup,
        # we simulate this replica readonly behaviour as such:
        $db->dbic->dbh->do("SET default_transaction_read_only TO 'on'");
    }

    return $db;
}

my $decoder = JSON::MaybeXS->new;
# this will help in calling functions in DB.
# result must be always rows of JSON
sub getall_arrayref {
    my ($self, $query, $params) = @_;

    my $result = $self->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare($query);
            $sth->execute(@$params);
            return $sth->fetchall_arrayref([0]);
        });

    my @result;
    try {
        @result = map { $decoder->decode($_->[0]) } @$result;
    } catch {
        die "Result must be always rows of JSON : $@";
    }

    return \@result;
}

=head2 get_duplicate_client

methods from BOM::Database::DataMapper::Client

This method will return clients which have the same details as provided

Excludes:

=over 4

=item  - Those marked with statuses passed in the "exclude_status" parameter

=item  - Client with the same email

=back

=cut

sub get_duplicate_client {
    my $self = shift;
    my $args = shift;

    my @params =
        (trim($args->{first_name}), trim($args->{last_name}), $args->{date_of_birth}, $args->{email}, $self->broker_code, $args->{phone});
    push @params, $args->{exclude_status} if $args->{exclude_status};

    my $dbic        = $self->db->dbic;
    my @dupe_record = $dbic->run(
        fixup => sub {
            return $_->selectrow_array(q{select * from get_duplicate_client(} . join(',', map { '?' } @params) . q{)}, undef, @params);
        });
    return @dupe_record;
}

sub get_next_fmbid {
    my $self = shift;

    my ($next_fmbid) = $self->db->dbh->selectrow_array("select nextval('sequences.bet_serial'::regclass)");

    return $next_fmbid;
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;
