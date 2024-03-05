use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::Fatal;
use Test::Exception;
use Test::Deep;

use Locale::Codes::Country qw(country_code2code);
use HTTP::Response;
use Future::Exception;
use JSON::MaybeXS;
use List::Util qw(uniq);

use Business::Config;
use BOM::Config::Onfido;
use BOM::Config::Redis;

my $id_supported_docs = ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'];
my $ng_supported_docs = ['Driving Licence', 'National Identity Card', 'Passport', 'Voter Id'];
my $gh_supported_docs = ['Driving Licence', 'National Identity Card', 'Passport'];

BOM::Config::Onfido::clear_supported_documents_cache();

subtest 'Check supported documents ' => sub {
    is_deeply(BOM::Config::Onfido::supported_documents_for_country('ID'), $id_supported_docs, 'Indonesia supported type is correct');
    is_deeply(BOM::Config::Onfido::supported_documents_for_country('NG'), $ng_supported_docs, 'Nigeria supported type is correct');
    is_deeply(BOM::Config::Onfido::supported_documents_for_country('GH'), $gh_supported_docs, 'Ghana supported type is correct');
};

subtest 'Check supported country ' => sub {
    ok BOM::Config::Onfido::is_country_supported('ID'), 'Indonesia is supported';
    ok BOM::Config::Onfido::is_country_supported('AO'), 'Bangladesh is supported';
    ok BOM::Config::Onfido::is_country_supported('GH'), 'Ghana is supported';
};

subtest 'Invalid country ' => sub {
    lives_ok { BOM::Config::Onfido::is_country_supported('I213') } 'Invalid county, but it wont die';
    lives_ok { BOM::Config::Onfido::is_country_supported(123) } 'Invalid county, but it wont die';
    is_deeply(BOM::Config::Onfido::supported_documents_for_country(123), [], 'Invalid county, returns empty list');
};

subtest 'disabled countries' => sub {
    my $config = Business::Config->new()->onfido_disabled_countries;

    my $disabled_countries = [map { $config->{$_} ? $_ : () } keys $config->%*];

    # there used to be repeated countries at config file?
    my @expected_disabled_countries = uniq(
        'af', 'by', 'cn', 'cd', 'ir', 'iq', 'ly', 'kp', 'ru', 'sy', 'aq', 'bq', 'bv', 'io', 'cx', 'cc', 'ck', 'cw', 'fk', 'gf', 'tf', 'gp',
        'hm', 'mq', 'yt', 'nc', 'nu', 'nf', 're', 'sh', 'pm', 'sx', 'gs', 'sj', 'tl', 'tk', 'um', 'us', 'wf', 'eh', 'ax', 'tf', 'bq', 'bv',
        'cc', 'ck', 'cw', 'cx', 'fk', 'gp', 'gf', 'hm', 'io', 'mq', 'yt', 'nc', 'nf', 'nu', 're', 'gs', 'sh', 'sj', 'pm', 'sx', 'tl'
    );

    for my $cc (@expected_disabled_countries) {
        ok BOM::Config::Onfido::is_disabled_country($cc),   "$cc is disabled";
        ok !BOM::Config::Onfido::is_country_supported($cc), "$cc is unsupported";
    }

    cmp_bag $disabled_countries, [@expected_disabled_countries], 'disabled countries full list';
};

subtest 'Onfido supported documents updater' => sub {
    my $conf_mock   = Test::MockModule->new('BOM::Config::Onfido');
    my $stats_event = {};

    $conf_mock->mock(
        'stats_event',
        sub {
            my ($title, $text, $opts) = @_;

            $stats_event = {
                title => $title,
                text  => $text,
                $opts->%*,
            };
        });

    my $redis = BOM::Config::Redis::redis_replicated_write();

    # clean all
    subtest 'clear cache' => sub {
        $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY, 'test');
        $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY,      'test');
        $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'ARG', 'test');
        $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'BRA', 'test');
        $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'COL', 'test');
        BOM::Config::Onfido::clear_supported_documents_cache();

        ok !$redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY), 'key deleted';
        ok !$redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY),      'key deleted';
        ok !$redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'ARG'), 'key deleted';
        ok !$redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'BRA'), 'key deleted';
        ok !$redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'COL'), 'key deleted';
    };

    BOM::Config::Onfido::clear_supported_documents_cache();

    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my $http_exception;
    my %countries;
    my $data;
    my $meta;

    $http_mock->mock(
        'get',
        sub {
            if ($http_exception) {
                return {
                    content => '',
                    status  => 404,
                    reason  => 'some exception',
                };
            }

            return {
                content => encode_json({
                        data => $data,
                        meta => $meta,
                    }
                ),
                status => 200,
                reason => 'ok',
            };
        });

    # undef data & meta

    $log->clear();
    $stats_event = {};
    $data        = undef;
    $meta        = undef;
    BOM::Config::Onfido::supported_documents_updater();

    my $document = $redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY);
    my $expected = undef;
    cmp_deeply $document, $expected, 'Expected undef documents on undef data & meta';

    $log->empty_ok('no logs founds');
    cmp_deeply $stats_event, {}, 'No event reported';

    # empty data & undef meta
    $stats_event = {};
    $log->clear();
    $data = [];
    $meta = undef;
    BOM::Config::Onfido::supported_documents_updater();

    $document = $redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY);
    $expected = undef;
    cmp_deeply $document, $expected, 'Expected undef documents on undef meta';
    $log->empty_ok('no logs founds');
    cmp_deeply $stats_event, {}, 'No event reported';

    # some docs & version undef
    $stats_event = {};
    $log->clear();
    $data = [{
            country_alpha3 => 'TST',
            document_type  => 'PPO'
        },
        {
            country_alpha3 => 'TST',
            document_type  => 'VIS',
            country        => 'Republic of Testers',
        },
        {
            country_alpha3 => 'TST',
            document_type  => 'PPO',
            country        => 'Republic of Testers',
        },
        {
            country_alpha3 => 'TST',
            document_type  => 'PPO',
            country        => 'Republic of Testers',
        },
        {
            country_alpha3 => 'TST',
            document       => 'CCC',
            country        => 'Republic of Testers',
        },
        {
            country_alpha3 => 'TST',
            document       => 'CCC'
        },
        {document_type => 'VIS'},
        {document      => 'VIS'},
        {
            country_alpha3 => 'SSS',
            document_type  => 'VIS',
            country        => 'The Kingdom of Super Simple Software',
        },
        {
            country_alpha3 => 'SSS',
            document       => 'VIS',
            country        => 'Kingdom of Super Simple Software',
        },
        {
            country_alpha3 => 'ATR',
            document       => 'VIS',
            country        => 'Autonomous Zone of Automatic Testing Robots',
        },
        {
            country_alpha3 => 'ATR',
            document_type  => 'VIS',
            country        => 'Autonomous Zone of Automatic Testing Robots',
        },
    ];
    $meta = {};
    BOM::Config::Onfido::supported_documents_updater();

    $document = $redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY);
    $expected = undef;
    cmp_deeply $document, $expected, 'Undef documents on undefined version';

    $log->empty_ok('no logs founds');
    cmp_deeply $stats_event, {}, 'No event reported';

    $meta = {version => 12345};
    BOM::Config::Onfido::supported_documents_updater();
    $log->empty_ok('no logs founds');

    cmp_deeply $stats_event,
        {
        title      => 'Onfido Supported documents',
        text       => 'updated to version 12345',
        alert_type => 'success',
        },
        'Successful event reported';

    is $redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY), 12345, 'expected version';

    $document = decode_json($redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY));
    $expected = [{
            doc_types_list => ['Visa'],
            country_name   => 'Autonomous Zone of Automatic Testing Robots',
            country_code   => 'ATR'
        },
        {
            country_name   => 'The Kingdom of Super Simple Software',
            doc_types_list => ['Visa'],
            country_code   => 'SSS'
        },
        {
            country_code   => 'TST',
            doc_types_list => ['Passport', 'Visa'],
            country_name   => 'Republic of Testers'
        }];

    cmp_deeply $document, $expected, 'Expected documents per country';

    # http exception
    $stats_event = {};
    $log->clear();
    $http_exception = 1;

    $meta = {version => 123456};
    $data = [];
    BOM::Config::Onfido::supported_documents_updater();
    $log->contains_ok(qr/Failed to update Onfido supported documents \- status=404/, 'Logged error due to status 404');

    cmp_deeply $stats_event,
        {
        title      => 'Onfido Supported documents',
        text       => 'failed to process the update',
        alert_type => 'error',
        },
        'Error event reported';

    is $redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY), 12345, 'expected version (no changes made)';

    cmp_deeply $document, $expected, 'Expected documents per country (no changes made)';

    # update docs
    $stats_event = {};
    $log->clear();
    $http_exception = 0;
    $meta           = {version => 123456};
    $data           = [{
            country_alpha3 => 'TST',
            document_type  => 'PPO'
        },
        {
            country_alpha3 => 'TST',
            document_type  => 'VIS',
            country        => 'Republic of Testers and Forsaken Devs',
        },
        {
            country_alpha3 => 'TST',
            document_type  => 'REP',
            country        => 'Republic of Testers and Forsaken Devs',
        },
        {
            country_alpha3 => 'TST',
            document_type  => 'PPO',
            country        => 'Republic of Testers and Forsaken Devs',
        },
        {
            country_alpha3 => 'TST',
            document_type  => 'PPO',
            country        => 'Republic of Testers and Forsaken Devs',
        },
        {
            country_alpha3 => 'TST',
            document       => 'CCC',
            country        => 'Republic of Testers and Forsaken Devs',
        },
        {
            country_alpha3 => 'TST',
            document       => 'CCC'
        },
        {document_type => 'VIS'},
        {document      => 'VIS'},
        {
            country_alpha3 => 'ATR',
            document_type  => 'REP',
            country        => 'Autonomous Zone of Automatic Testing Robots',
        },
    ];
    BOM::Config::Onfido::supported_documents_updater();
    $log->empty_ok('empty logs');
    cmp_deeply $stats_event,
        {
        title      => 'Onfido Supported documents',
        text       => 'updated to version 123456',
        alert_type => 'success',
        },
        'Successful event reported';

    $document = decode_json($redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY));
    $expected = [{
            doc_types_list => ['Residence Permit'],
            country_name   => 'Autonomous Zone of Automatic Testing Robots',
            country_code   => 'ATR'
        },
        {
            country_code   => 'TST',
            doc_types_list => ['Passport', 'Residence Permit', 'Visa'],
            country_name   => 'Republic of Testers and Forsaken Devs'
        }];

    cmp_deeply $document, $expected, 'Expected documents per country';

    # delete some countries
    $stats_event = {};
    $meta        = {version => 123457};
    $data        = [{
            country_alpha3 => 'ATR',
            document_type  => 'REP',
            country        => 'Empire of the Automatic Testing Robots',
        },
    ];

    BOM::Config::Onfido::supported_documents_updater();
    $log->empty_ok('empty logs');
    cmp_deeply $stats_event,
        {
        title      => 'Onfido Supported documents',
        text       => 'updated to version 123457',
        alert_type => 'success',
        },
        'Successful event reported';

    $document = decode_json($redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY));
    $expected = [{
            country_code   => 'TST',
            doc_types_list => ['Residence Permit',],
            country_name   => 'Empire of the Automatic Testing Robots'
        }];

    # empty again
    $stats_event = {};
    $meta        = {version => 123458};
    $data        = [];
    BOM::Config::Onfido::supported_documents_updater();
    $log->empty_ok('empty logs');
    cmp_deeply $stats_event,
        {
        title      => 'Onfido Supported documents',
        text       => 'updated to version 123458',
        alert_type => 'success',
        },
        'Successful event reported';

    $document = decode_json($redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY));
    $expected = [];
    cmp_deeply $document, $expected, 'Expected documents per country';

    # dont process unchanged version
    $stats_event = {};
    $meta        = {version => 123458};
    $data        = [{
            country_alpha3 => 'ATR',
            document_type  => 'REP',
            country        => 'Empire of the Automatic Testing Robots',
        },
    ];
    BOM::Config::Onfido::supported_documents_updater();
    $log->empty_ok('empty logs');
    cmp_deeply $stats_event, {}, 'unchanged version not reported';

    $document = decode_json($redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY));
    $expected = [];
    cmp_deeply $document, $expected, 'Expected documents per country';

    BOM::Config::Onfido::clear_supported_documents_cache();
    $http_mock->unmock_all;
};

subtest 'document configuration with redis' => sub {
    # this is bad we need the desired keys
    ok !test_country_hashref_keys({TST => {test => 1}});

    my $mock = Test::MockModule->new('BOM::Config::Onfido');
    my $hits = 0;
    $mock->mock(
        'supported_documents_list',
        sub {
            $hits++;
            return $mock->original('supported_documents_list')->(@_);
        });

    my $redis   = BOM::Config::Redis::redis_replicated_write();
    my $details = BOM::Config::Onfido::_get_country_details();
    BOM::Config::Onfido::_get_country_details() for (1 .. 10);
    is $hits, 0, 'cache hit';

    # bring a new version
    $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY, 1);

    my $new_details = BOM::Config::Onfido::_get_country_details();
    is $hits, 1, 'new version hit';

    my @doc_bag = ();

    for my $country (keys $new_details->%*) {
        push @doc_bag, $new_details->{$country}->{doc_types_list}->@*;
    }

    ok test_country_hashref_keys($new_details);
    is scalar @doc_bag, 693, 'Document stash taken from the YML';

    # inject some info
    $redis->set(
        +BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY,
        encode_json([{
                    country_code   => 'TST',
                    country_name   => 'Republic of Testers and Forsaken Devs',
                    doc_types_list => ['Passport', 'Visa'],
                },
                {
                    country_code   => 'ATR',
                    doc_types_list => ['Passport', 'Residence Permit'],
                    country_name   => 'Empire of the Automatic Testing Robots',
                }]));

    $new_details = BOM::Config::Onfido::_get_country_details();
    @doc_bag     = ();

    for my $country (keys $new_details->%*) {
        push @doc_bag, $new_details->{$country}->{doc_types_list}->@*;
    }

    ok test_country_hashref_keys($new_details);
    is scalar @doc_bag, 693, 'Still taken from the YML as the version remains the same';
    is $hits,           1,   'same version hit';

    # bump the version
    $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY, 2);
    $new_details = BOM::Config::Onfido::_get_country_details();
    is $hits, 2, 'new version hit';

    ok test_country_hashref_keys($new_details);
    cmp_bag $new_details->{ATR}->{doc_types_list}, ['Passport', 'Residence Permit'], 'Expected docs for ATR';
    cmp_bag $new_details->{TST}->{doc_types_list}, ['Passport', 'Visa'],             'Expected docs for TST';

    # bump the version
    $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY, 3);
    $redis->set(
        +BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY,
        encode_json([{
                    country_code   => 'SSS',
                    country_name   => 'Republic of Super Simple Software',
                    doc_types_list => ['Passport'],
                },
                {
                    country_code   => 'ATR',
                    doc_types_list => ['Passport', 'Residence Permit'],
                    country_name   => 'Empire of the Automatic Testing Robots',
                }]));

    $new_details = BOM::Config::Onfido::_get_country_details();
    is $hits, 3, 'new version hit';

    ok test_country_hashref_keys($new_details);
    is $new_details->{TST}, undef, 'Expected undef TST';
    cmp_bag $new_details->{SSS}->{doc_types_list}, ['Passport'],                     'Expected docs for SSS';
    cmp_bag $new_details->{ATR}->{doc_types_list}, ['Passport', 'Residence Permit'], 'Expected docs for ATR';
    BOM::Config::Onfido::clear_supported_documents_cache();

    # bad json
    $log->clear();
    $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY, 4);
    $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_DOCUMENTS_KEY,      '{bad:json}');
    $new_details = BOM::Config::Onfido::_get_country_details();
    @doc_bag     = ();

    for my $country (keys $new_details->%*) {
        push @doc_bag, $new_details->{$country}->{doc_types_list}->@*;
    }

    ok test_country_hashref_keys($new_details);
    is scalar @doc_bag, 693, 'it has fallen back to YML';
    is $hits,           4,   'new version hit';

    $log->contains_ok('Could not read Onfido supported documents from redis key: ONFIDO::SUPPORTED::DOCUMENTS::STASH');

    $mock->unmock_all;
};

# all hashref within the list of countries must have all the desired keys

sub test_country_hashref_keys {
    my $list = shift;

    return List::Util::all { $_ } map { @{$_}{qw/country_name doc_types_list country_code/} } values $list->%*;
}

done_testing();
