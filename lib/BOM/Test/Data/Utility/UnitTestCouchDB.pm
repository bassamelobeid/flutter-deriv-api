package BOM::Test::Data::Utility::UnitTestCouchDB;

=head1 NAME

BOM::Test::Data::Utility::UnitTestCouchDB

=head1 DESCRIPTION

To be used by an RMG unit test. Changes the names of our CouchDB databases
for the duration of the test run, so that data added and modified by
the test doesn't clash with data being used by other code running on the
server.

=head1 SYNOPSIS

  use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);

=cut

use 5.010;
use strict;
use warnings;

use BOM::MarketData::CorrelationMatrix;
use BOM::MarketData::EconomicEvent;
use BOM::Platform::Runtime;
use CouchDB::Client;
use Carp qw( croak );
use LWP::UserAgent;
use YAML::XS;

use BOM::MarketData::ExchangeConfig;
use BOM::MarketData::VolSurface::Delta;
use BOM::MarketData::VolSurface::Flat;
use BOM::MarketData::VolSurface::Phased;
use BOM::MarketData::VolSurface::Moneyness;

# For the unit_test_couchdb.t test case, we limit the dabase name to three characters
# ie 'bom', 'vol', 'int, etc. all have three characters each
my %couchdb_databases = (
    bom                  => 'zz' . (time . int(rand 999999)) . 'bom',
    volatility_surfaces  => 'zz' . (time . int(rand 999999)) . 'vol',
    interest_rates       => 'zz' . (time . int(rand 999999)) . 'int',
    dividends            => 'zz' . (time . int(rand 999999)) . 'div',
    economic_events      => 'zz' . (time . int(rand 999999)) . 'eco',
    correlation_matrices => 'zz' . (time . int(rand 999999)) . 'cor',
    corporate_actions    => 'zz' . (time . int(rand 999999)) . 'coa',
    currency_config      => 'zz' . (time . int(rand 999999)) . 'cuc',
    exchange_config      => 'zz' . (time . int(rand 999999)) . 'exc',
);

sub _init {
    my $env = BOM::Platform::Runtime->instance->datasources;

    my $ua = LWP::UserAgent->new();
    $ua->ssl_opts(
        verify_hostname => 0,
        SSL_verify_mode => 'SSL_VERIFY_NONE'
    );
    my $couch = CouchDB::Client->new(
        uri => $env->couchdb->replica->uri,
        ua  => $ua
    );

    _teardown($couch);

    $env->couchdb_databases(\%couchdb_databases);

    _bootstrap($couch);

    return 1;
}

sub _bootstrap {
    my $couch = shift;

    foreach my $db_name (values %couchdb_databases) {
        my $db = $couch->newDB($db_name)
            || croak 'Could not get a Couch::Client::DB';
        $db->create || croak 'Could not create  ' . $db_name;

        if ($db_name =~ /bom$/) {
            $db->newDoc('app_settings')->create;
        }

        add_design_doc($db) if ($db_name !~ /bom$/);
    }

    return 1;
}

sub _teardown {
    my $couch = shift;

    return if keep_db();

    map { $_->delete if ($_->dbInfo->{db_name} =~ /^zz\d+[a-z]+$/) } @{$couch->listDBs};

    return 1;
}

=head2 add_design_doc

Adds the design doc that provides historical lookup of documents by date.

=cut

sub add_design_doc {
    my $db = shift;

    my $design_doc_name = '_design/docs';

    if ($db->designDocExists($design_doc_name)) {
        warn 'Design doc for ' . $db->dbInfo->{db_name} . ' already exists. Skipping.';
        return;
    }

    # needs a different design/docs for economic_events db
    if ($db->dbInfo->{db_name} =~ /^zz\d+eco$/) {
        return $db->newDesignDoc(
            $design_doc_name,
            undef,
            {
                views => {
                    by_release_date => {
                        map => 'function(doc) {emit([doc.source,doc.release_date], doc)}',
                    },
                    by_recorded_date => {
                        map => 'function(doc) {emit([doc.source,doc.recorded_date], doc)}',
                    },
                    existing_events => {
                        map => 'function(doc) {emit([doc.symbol,doc.release_date,doc.event_name])}',
                    },
                },
            })->create;
    }

    if ($db->dbInfo->{db_name} =~ /^zz\d+exc$/) {
        return $db->newDesignDoc(
            $design_doc_name,
            undef,
            {
                views => {
                    by_trading_timezone => {
                        map => 'function(doc) {emit([doc.trading_timezone], doc)}',
                    },
                    by_bloomberg_calendar_code => {
                        map => 'function(doc) {emit([doc.bloomberg_calendar_code], doc)}',
                    },
                },
            })->create;
    }

    if ($db->dbInfo->{db_name} =~ /^zz\d+cuc$/) {
        return $db->newDesignDoc(
            $design_doc_name,
            undef,
            {
                views => {
                    by_bloomberg_country_code => {
                        map => 'function(doc) {emit([doc.bloomberg_country_code], doc)}',
                    },
                    by_bloomberg_calendar_code => {
                        map => 'function(doc) {emit([doc.bloomberg_calendar_code], doc)}',
                    },
                },
            })->create;
    }

    return $db->newDesignDoc(
        $design_doc_name,
        undef,
        {
            views => {
                by_date => {
                    map => 'function(doc) {emit([doc.symbol, doc.date], doc)}',
                },
            },
        })->create;
}

=head2 create doc()

    Create a new document in the test database

    params:
    $yaml_couch_db  => The name of the entity in the YAML file (eg. promo_code)
    $data_mod       => hasref of modifictions required to the data (optional)

=cut

sub create_doc {
    my ($yaml_couch_db, $data_mod) = @_;

    my $save = 1;
    if (exists $data_mod->{save}) {
        $save = delete $data_mod->{save};
    }

    # get data to insert
    my $fixture = YAML::XS::LoadFile('/home/git/regentmarkets/bom/t/data/couch_unit_test.yml');
    my $data    = $fixture->{$yaml_couch_db}{data};

    # modify data?
    for (keys %$data_mod) {
        $data->{$_} = $data_mod->{$_};
    }

    # use class to create the Couch doc
    my $class_name = $fixture->{$yaml_couch_db}{class_name};
    my $obj        = $class_name->new($data);

    if ($save) {
        $obj->save;
    }

    return $obj;
}

sub import {
    my ($class, $init) = @_;
    _init() if $init && $init eq ':init';
    return;
}

=head2 keep_db

Tells UnitTestCouchDB not to destroy the test database at the end of testing

If you need to debug tests and wants to keep couch data,
just call anywhere from your test file:

C<BOM::Test::Data::Utility::UnitTestCouchDB::keep_db(1);>

=cut

sub keep_db {
    state $KEEPDB = 0;
    ($KEEPDB) = @_ if @_;
    return $KEEPDB;
}

END {
    my $ua = LWP::UserAgent->new();
    $ua->ssl_opts(
        verify_hostname => 0,
        SSL_verify_mode => 'SSL_VERIFY_NONE'
    );
    _teardown(
        CouchDB::Client->new(
            uri => BOM::Platform::Runtime->instance->datasources->couchdb->replica->uri,
            ua  => $ua
        ));
}

1;
