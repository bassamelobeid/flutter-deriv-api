package BOM::Database::ClientDB;

use Carp;
use Moose;
use File::ShareDir;
use JSON::MaybeXS;
use LandingCompany::Registry;
use Try::Tiny;
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
    $domain = ((
            (BOM::Config::on_qa() and $db_postfix eq '_test')
                or BOM::Config::on_development())
            and $self->{operation} ne 'collector'
    ) ? 'svg' : $domain;

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

    if (BOM::Config->env() =~ /(^development$)|(^qa)/
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
    }
    catch {
        die "Result must be always rows of JSON : $_";
    };

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

    my $dupe_sql    = "SELECT * FROM get_duplicate_client(?,?,?,?,?,?,?)";
    my $dbic        = $self->db->dbic;
    my @dupe_record = $dbic->run(
        fixup => sub {
            my $dupe_sth = $_->prepare($dupe_sql);
            $dupe_sth->bind_param(1, uc $args->{first_name});
            $dupe_sth->bind_param(2, uc $args->{last_name});
            $dupe_sth->bind_param(3, $args->{date_of_birth});
            $dupe_sth->bind_param(4, $args->{email});
            $dupe_sth->bind_param(5, $self->broker_code);
            $dupe_sth->bind_param(6, $args->{phone});
            $dupe_sth->bind_param(7, $args->{exclude_status} // ['duplicate_account']);
            $dupe_sth->execute();
            return $dupe_sth->fetchrow_array();
        });
    return @dupe_record;
}

sub lock_client_loginid {
    my $self = shift;
    my $client_loginid = shift || $self->loginid;

    my $dbic   = $self->db->dbic;
    my $result = $dbic->run(
        ping => sub {
            $_->do('SET synchronous_commit=local');

            my $sth = $_->prepare('SELECT lock_client_loginid($1)');
            $sth->execute($client_loginid);

            $_->do('SET synchronous_commit=on');
            return $sth->fetchrow_arrayref;
        });

    return 1 if ($result and $result->[0]);

    return;
}

BEGIN {
    *freeze = \&lock_client_loginid;
}

sub unlock_client_loginid {
    my $self = shift;
    my $client_loginid = shift || $self->loginid;

    my $dbic   = $self->db->dbic;
    my $result = $dbic->run(
        ping => sub {
            $_->do('SET synchronous_commit=local');

            my $sth = $_->prepare('SELECT unlock_client_loginid($1)');
            $sth->execute($client_loginid);

            $_->do('SET synchronous_commit=on');
            return $sth->fetchrow_arrayref;
        });

    return 1 if ($result and $result->[0]);

    return;
}

BEGIN {
    *unfreeze = \&unlock_client_loginid;
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;
