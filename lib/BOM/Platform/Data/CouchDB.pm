package BOM::Platform::Data::CouchDB;

=head1 NAME

BOM::Platform::Data::CouchDB

=head1 SYNOPSYS

    my $couchdb = BOM::Platform::Data::CouchDB->new(
        replica_host   => 'localhost',
        replica_port   => 5432,
        master_host   => 'localhost',
        master_port   => 5432,
        couch => 'testdb',
    );

It is built for you from I<BOM::Platform::Data::Sources>.
    my $couchdb = BOM::Platform::Runtime->instance->datasources->couchdb

=head1 DESCRIPTION

This class represents couchdb as a datasource.

=head1 ATTRIBUTES

=cut

use Moose;
use MooseX::StrictConstructor;
use namespace::autoclean;

use Cache::RedisDB;
use BOM::Platform::Data::CouchDB::Connection;
use Try::Tiny;
use LWP::UserAgent;

=head2 name

name of this definition in environment.yml

=cut

has name => (
    is  => 'ro',
    isa => 'Str'
);

=head2 db

db with which to operate.

=cut

has db => (
    is      => 'ro',
    isa     => 'Str',
    default => 'bom',
);

=head2 couchdb

password for "couchdb" user

=cut

has couchdb => (
    is      => 'ro',
    default => '7%U4l$ogFl',
);

=head2 replica_host

name of the host to read from.

=cut

has 'replica_host' => (
    is      => 'ro',
    default => 'localhost',
);

=head2 replica_port

port number in replica_host through which we can read.

=cut

has replica_port => (
    is      => 'ro',
    default => '5984',
);

=head2 replica_protocol

 protcol used to read.

=cut

has replica_protocol => (
    is  => 'ro',
    isa => 'Str',
);

=head2 master_host

name of the host to write to

=cut

has 'master_host' => (
    is      => 'ro',
    default => 'localhost',
);

=head2 master_port

port number in master_host through which we can write.

=cut

has master_port => (
    is      => 'ro',
    default => '5984',
);

=head2 master_protocol

protocol used to write.

=cut

has master_protocol => (
    is  => 'ro',
    isa => 'Str',
);

=head2 replica

The internal ds used to read from couchdb

=cut

has replica => (
    is         => 'ro',
    isa        => 'BOM::Platform::Data::CouchDB::Connection',
    lazy_build => 1,
);

=head2 master

The internal ds used to write to couchdb

=cut

has master => (
    is         => 'ro',
    isa        => 'BOM::Platform::Data::CouchDB::Connection',
    lazy_build => 1,
);

=head2 ua

Optionally passed ua(user_agent). If not passed the couchdb's default ua is used.

=cut

has ua => (
    is  => 'ro',
    isa => 'Maybe[LWP::UserAgent]',
);

=head1 METHODS

=head2 document

Get or set a couch document.

Usage,
    To get a document
        $couchdb->document($doc_id);

    To set a document
        $couchdb->document($doc_id, $data);

        $data is a HashRef


=cut

my $cache_namespace = 'COUCH_DOCS';

sub document {
    my $self = shift;
    my $doc  = shift;
    my $data = shift;

    my $cache_key = $self->db . '_' . $doc;
    if ($data) {
        Cache::RedisDB->del($cache_namespace, $cache_key) if ($self->_can_cache);
        $data = $self->master->document($doc, $data);
    } else {
        $data = Cache::RedisDB->get($cache_namespace, $cache_key) if ($self->_can_cache);

        if (not $data) {
            $data = $self->replica->document($doc);
            Cache::RedisDB->set($cache_namespace, $cache_key, $data, 127)
                if ($data and $self->_can_cache);
        }
    }

    return $data;
}

=head2 view

Query a couchdb view

Usage,
    Without Parameters
        $couchdb->view($db, $viewname);

    With Parameters
        $couchdb->view($db, $viewname, $parameters);

        $parameters is a HashRef


=cut

sub view {
    my $self   = shift;
    my $view   = shift;
    my $params = shift;

    return $self->replica->view($view, $params);
}

=head2 document_present

A syntatic sugar to check if a document

Usage,
    if ($couchdb->document_present($doc_id)) {
        ....
    }

Throws,
    Nothing

Returns,
    1     - if document is found.
    undef - if document is not found.

=cut

sub document_present {
    my $self = shift;
    my $doc  = shift;

    try { $self->replica->document($doc); } or return;

    return 1;
}

=head2 create_document

Creates a couch document

Usage,
    my $doc_id = $couchdb->create_document($doc_id);

=cut

sub create_document {
    my $self = shift;
    my $doc  = shift;

    return $self->master->create_document($doc);
}

=head2 delete_document

Deletes a couch document

Usage,
    $couchdb->delete_document($doc_id);

=cut

sub delete_document {
    my $self = shift;
    my $doc  = shift;

    return $self->master->delete_document($doc);
}

=head2 create_database

Creates a CouchDB Database.

Usage,
    $couchdb->create_database($db);


=cut

sub create_database {
    my $self = shift;

    return $self->master->create_database();
}

=head2 can_read

Confirms that you can read from this couchdb

Usage,
    if($couchdb->can_read) {
        ...
    }

Returns,
    1     - can read
    undef - otherwise
=cut

sub can_read {
    my $self = shift;
    return $self->replica->can_connect;
}

=head2 can_write

Confirms that you can write to this couchdb

Usage,
    if($couchdb->can_write) {
        ...
    }

Returns,
    1     - can write
    undef - otherwise

=cut

sub can_write {
    my $self = shift;
    return $self->master->can_connect;
}

sub _build_replica {
    my $self   = shift;
    my $params = {};

    $params->{host} = $self->replica_host;
    $params->{port} = $self->replica_port;
    $params->{db}   = $self->db;

    $params->{protocol} = $self->replica_protocol if ($self->replica_protocol);
    $params->{couchdb}  = $self->couchdb          if ($self->couchdb);

    return BOM::Platform::Data::CouchDB::Connection->new(%$params);
}

sub _build_master {
    my $self   = shift;
    my $params = {};

    $params->{host} = $self->master_host;
    $params->{port} = $self->master_port;
    $params->{db}   = $self->db;

    $params->{protocol} = $self->master_protocol if ($self->master_protocol);
    $params->{couchdb}  = $self->couchdb         if ($self->couchdb);

    return BOM::Platform::Data::CouchDB::Connection->new(%$params);
}

has '_can_cache' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__can_cache {
    return try { Cache::RedisDB::redis_connection(); 1; };
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut
