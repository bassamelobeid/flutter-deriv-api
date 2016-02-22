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
use BOM::MarketData::EconomicEventCalendar;
use BOM::Platform::Runtime;
use CouchDB::Client;
use Carp qw( croak );
use LWP::UserAgent;
use YAML::XS;

use BOM::MarketData::VolSurface::Delta;
use BOM::MarketData::VolSurface::Phased;
use BOM::MarketData::VolSurface::Moneyness;
use BOM::System::Chronicle;
use BOM::System::RedisReplicated;
use JSON;

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
);

sub initialize_symbol_dividend {
    my $symbol = shift;
    my $rate   = shift;

    my $document = {
        symbol          => $symbol,
        rates           => {'365' => $rate},
        discrete_points => undef
    };

    my $dv = BOM::MarketData::Dividend->new(symbol => $symbol);
    $dv->document($document);
    return $dv->save;
}

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

    #delete chronicle data too (Redis and Pg)
    BOM::System::RedisReplicated::redis_write()->flushall;
    BOM::System::Chronicle::_dbh()->do('delete from chronicle;') if BOM::System::Chronicle::_dbh();
    BOM::System::Chronicle::set(
        'app_settings',
        'binary',
        {
            'global' => {
                'payments'  => {},
                'marketing' => {},
                'system'    => {
                    'suspend' => {
                        'new_accounts'   => 0,
                        'payments'       => 0,
                        'payment_agents' => 0,
                        'system'         => '0',
                        'trading'        => '0',
                        'all_logins'     => '0',
                        'logins'         => []}
                },
                'cgi' => {
                    'allowed_languages' => ['EN', 'ID', 'RU', 'ZH_CN'],
                    'backoffice'               => {'static_url' => 'https://regentmarkets.github.io/binary-static-backoffice/'},
                    'terms_conditions_version' => 'Version 39 2015-12-04'
                },
                'quants' => {
                    'underlyings' => {'disabled_due_to_corporate_actions' => []},
                    'markets'     => {
                        'disabled'   => ['sectors'],
                        'disable_iv' => []
                    },
                    'features' => {
                        'suspend_claim_types' => [],
                    },
                    'client_limits' => {
                        'asian_turnover_limit'       => '50000',
                        'spreads_daily_profit_limit' => '10000',
                        'intraday_forex_iv'          => '{
                               "potential_profit" : 35000,
                               "realized_profit" : 35000,
                               "turnover" : 35000
                            }',
                        'tick_expiry_engine_turnover_limit' => '0.5'
                    },
                    'commission' => {
                        'adjustment' => {
                            'global_scaling' => '100',
                        }}}
            },
            '_rev' => time
        });
    BOM::Platform::Runtime->instance(undef);

    initialize_symbol_dividend "R_25",    0;
    initialize_symbol_dividend "R_50",    0;
    initialize_symbol_dividend "R_75",    0;
    initialize_symbol_dividend "R_100",   0;
    initialize_symbol_dividend "RDBULL",  -35;
    initialize_symbol_dividend "RDBEAR",  20;
    initialize_symbol_dividend "RDSUN",   0;
    initialize_symbol_dividend "RDMOON",  0;
    initialize_symbol_dividend "RDMARS",  0;
    initialize_symbol_dividend "RDVENUS", 0;
    initialize_symbol_dividend "RDYANG",  -35;
    initialize_symbol_dividend "RDYIN",   20;

    BOM::System::Chronicle::set(
        'interest_rates',
        'JPY-USD',
        JSON::from_json(
            "{\"symbol\":\"JPY-USD\",\"rates\":{\"365\":\"2.339\",\"180\":\"2.498\",\"90\":\"2.599\",\"30\":\"2.599\",\"7\":\"2.686\"},\"date\":\"2016-01-26T17:00:03Z\",\"type\":\"market\"}"
        ));
    BOM::System::Chronicle::set('economic_events', 'economic_events', {events => []});

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
    my $fixture = YAML::XS::LoadFile('/home/git/regentmarkets/bom-test/data/couch_unit_test.yml');
    my $data    = $fixture->{$yaml_couch_db}{data};

    die "Invalid yaml couch db name: $yaml_couch_db" if not defined $data;

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
