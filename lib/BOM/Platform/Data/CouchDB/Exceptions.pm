package BOM::Platform::Data::CouchDB::Exceptions;

use strict;
use warnings;

use Exception::Class (

    'BOM::Platform::Data::CouchDB::Exception' => {
        fields => ['uri', 'error'],
        isa    => 'Exception::Class::Base'
    },

    'BOM::Platform::Data::CouchDB::ConnectionFailed' => {
        isa         => 'BOM::Platform::Data::CouchDB::Exception',
        description => 'Connection to couch db failed',
    },

    'BOM::Platform::Data::CouchDB::DBNotFound' => {
        isa         => 'BOM::Platform::Data::CouchDB::Exception',
        description => 'The DB you are looking for does not exist',
        fields      => ['uri', 'error', 'db'],
    },

    'BOM::Platform::Data::CouchDB::RetrieveFailed' => {
        isa         => 'BOM::Platform::Data::CouchDB::Exception',
        description => 'Document is not found in couch',
        fields      => ['db', 'uri', 'error', 'document'],
    },

    'BOM::Platform::Data::CouchDB::RevisionNotMatched' => {
        isa         => 'BOM::Platform::Data::CouchDB::Exception',
        description => 'Revision of document provided not match the one in couch',
        fields      => ['db', 'uri', 'error', 'document'],
    },

    'BOM::Platform::Data::CouchDB::UpdateFailed' => {
        isa         => 'BOM::Platform::Data::CouchDB::Exception',
        description => 'Revision of document provided not match the one in couch',
        fields      => ['db', 'uri', 'error', 'document'],
    },

    'BOM::Platform::Data::CouchDB::QueryFailed' => {
        isa         => 'BOM::Platform::Data::CouchDB::Exception',
        description => 'Revision of document provided not match the one in couch',
        fields      => ['db', 'uri', 'error', 'view'],
    },
);

sub full_message { my $self = shift; return 'Connection to db ' . $self->db . '@' . $self->uri . ' failed with error ' . $self->error; }

1;
