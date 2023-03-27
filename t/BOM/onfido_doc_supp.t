use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::Fatal;
use Test::Exception;
use Test::Deep;

use BOM::Config::Onfido;
use Locale::Codes::Country qw(country_code2code);
use BOM::Config::Redis;
use HTTP::Response;
use Future::Exception;
use JSON::MaybeXS;
use List::Util qw(uniq);

my $id_supported_docs = ['Driving Licence', 'National Identity Card', 'Passport', 'Residence Permit'];
my $ng_supported_docs = ['Driving Licence', 'National Identity Card', 'Passport', 'Voter Id'];
my $gh_supported_docs = ['Driving Licence', 'National Identity Card', 'Passport'];

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
    my $config = BOM::Config::Onfido::supported_documents_list();

    my $disabled_countries = [map { $_->{disabled} ? $_->{country_code} : () } values $config->@*];

    # there used to be repeated countries at config file?
    my @expected_disabled_countries = uniq(
        'af', 'by', 'cn', 'cd', 'ir', 'iq', 'ly', 'kp', 'ru', 'sy', 'aq', 'bq', 'bv', 'io', 'cx', 'cc', 'ck', 'cw', 'fk', 'gf', 'tf', 'gp',
        'hm', 'mq', 'yt', 'nc', 'nu', 'nf', 're', 'sh', 'pm', 'sx', 'gs', 'sj', 'tl', 'tk', 'um', 'wf', 'eh', 'ax', 'tf', 'bq', 'bv', 'cc',
        'ck', 'cw', 'cx', 'fk', 'gp', 'gf', 'hm', 'io', 'mq', 'yt', 'nc', 'nf', 'nu', 're', 'gs', 'sh', 'sj', 'pm', 'sx', 'tl'
    );

    for my $cc (@expected_disabled_countries) {
        ok BOM::Config::Onfido::is_disabled_country($cc),   "$cc is disabled";
        ok !BOM::Config::Onfido::is_country_supported($cc), "$cc is unsupported";
    }

    my $expected_3alpha = [map { uc(country_code2code($_, 'alpha-2', 'alpha-3')); } @expected_disabled_countries];

    cmp_bag $disabled_countries, $expected_3alpha, 'disabled countries full list';
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
    my @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    $redis->del($_) for @redis_keys;
    $redis->del(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY);

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

    # undef data

    $log->clear();
    $stats_event = {};
    $data        = undef;
    BOM::Config::Onfido::supported_documents_updater();

    @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    ok !scalar @redis_keys, 'Empty redis on empty data';
    $log->empty_ok('no logs founds');
    cmp_deeply $stats_event, {}, 'No event reported';

    # empty data
    $stats_event = {};
    $log->clear();
    $data = [];
    BOM::Config::Onfido::supported_documents_updater();

    @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    ok !scalar @redis_keys, 'Empty redis on empty data';
    $log->empty_ok('no logs founds');
    cmp_deeply $stats_event, {}, 'No event reported';

    # some docs
    $stats_event = {};
    $log->clear();
    $data = [{
            country_alpha3 => 'TST',
            document_type  => 'VIS'
        },
        {
            country_alpha3 => 'TST',
            document_type  => 'VIS'
        },
        {
            country_alpha3 => 'TST',
            document       => 'CCC'
        },
        {document_type => 'VIS'},
        {document      => 'VIS'},
        {
            country_alpha3 => 'SSS',
            document_type  => 'VIS'
        },
        {
            country_alpha3 => 'SSS',
            document       => 'VIS'
        },
        {
            country_alpha3 => 'ATR',
            document       => 'VIS'
        },
    ];
    BOM::Config::Onfido::supported_documents_updater();
    ok !scalar @redis_keys, 'Empty redis on undefined version';
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
    @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    %countries  = map { ($_ => $redis->smembers(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_)) } qw/TST SSS/;

    cmp_bag [@redis_keys], [map { +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_ } qw/TST SSS/], 'Expected countries';
    cmp_deeply { %countries },
        +{
        TST => bag(qw/VIS/),
        SSS => bag(qw/VIS/),
        },
        'Expected documents per country';

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

    is $redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY), 12345, 'expected version';
    @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    %countries  = map { ($_ => $redis->smembers(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_)) } qw/TST SSS/;

    cmp_bag [@redis_keys], [map { +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_ } qw/TST SSS/], 'Expected countries';
    cmp_deeply { %countries },
        +{
        TST => bag(qw/VIS/),
        SSS => bag(qw/VIS/),
        },
        'Expected documents per country';

    # update docs
    $stats_event = {};
    $log->clear();
    $http_exception = 0;
    $meta           = {version => 123456};
    $data           = [{
            country_alpha3 => 'TST',
            document_type  => 'VIS'
        },
        {
            country_alpha3 => 'TST',
            document_type  => 'CCC'
        },
        {
            country_alpha3 => 'TST',
            document       => 'VIS'
        },
        {
            country_alpha3 => 'SSS',
            document_type  => 'RT'
        },
        {
            country_alpha3 => 'SSS',
            document       => 'TX'
        },
        {
            country_alpha3 => 'SSS',
            document_type  => 'TX'
        },
        {
            country_alpha3 => 'ATR',
            document_type  => 'VIS'
        },
        {
            country_alpha3 => 'SSS',
            document_type  => 'TX'
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

    is $redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY), 123456, 'expected version';
    @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    %countries  = map { ($_ => $redis->smembers(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_)) } qw/TST SSS ATR/;

    cmp_bag [@redis_keys], [map { +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_ } qw/TST ATR/], 'Expected countries';
    cmp_deeply { %countries },
        +{
        TST => bag(qw/VIS/),
        SSS => bag(),
        ATR => bag(qw/VIS/),
        },
        'Expected documents per country';

    # delete some docs
    $stats_event = {};
    $meta        = {version => 123457};
    $data        = [{
            country_alpha3 => 'ATR',
            document_type  => 'VIS'
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

    @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    %countries  = map { ($_ => $redis->smembers(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_)) } qw/ATR/;

    cmp_bag [@redis_keys], [map { +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_ } qw/ATR/], 'Expected countries';
    cmp_deeply { %countries },
        +{
        ATR => bag(qw/VIS/),
        },
        'Expected documents per country';

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

    is $redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY), 123458, 'expected version';
    @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    ok !scalar @redis_keys, 'Empty redis on empty data';

    %countries = map { ($_ => $redis->smembers(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_)) } qw/SSS TST ATR/;

    cmp_deeply { %countries },
        +{
        SSS => [],
        TST => [],
        ATR => [],
        },
        'Expected empty docs';

    # dont process unchanged version
    $stats_event = {};
    $meta        = {version => 123458};
    $data        = [{
            country_alpha3 => 'TST',
            document_type  => 'VIS'
        },
    ];
    BOM::Config::Onfido::supported_documents_updater();
    $log->empty_ok('empty logs');
    cmp_deeply $stats_event, {}, 'unchanged version not reported';

    is $redis->get(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY), 123458, 'expected version';
    @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    ok !scalar @redis_keys, 'Empty redis on empty data';

    %countries = map { ($_ => $redis->smembers(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . $_)) } qw/SSS TST ATR/;

    cmp_deeply { %countries },
        +{
        SSS => [],
        TST => [],
        ATR => [],
        },
        'Expected empty docs';

    $redis->del($_) for @redis_keys;
    $redis->del(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY);
    $http_mock->unmock_all;
};

subtest 'document configuration with redis' => sub {
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

    is scalar @doc_bag, 0, 'Empty docs for every country';

    # bring some info
    $redis->sadd(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'ARG', 'DLD', 'TEST', 'VIS');
    $redis->sadd(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'GHA', 'PPO', 'TEST', 'NIC');

    BOM::Config::Onfido::_get_country_details();
    $new_details = BOM::Config::Onfido::_get_country_details();
    @doc_bag     = ();

    for my $country (keys $new_details->%*) {
        push @doc_bag, $new_details->{$country}->{doc_types_list}->@*;
    }

    is scalar @doc_bag, 0, 'Empty docs for every country still';
    is $hits,           1, 'same version hit';

    # bump the version
    $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY, 2);
    $new_details = BOM::Config::Onfido::_get_country_details();
    is $hits, 2, 'new version hit';

    cmp_bag $new_details->{ARG}->{doc_types_list}, ['Driving Licence', 'Visa'],                   'Expected docs for ARG';
    cmp_bag $new_details->{GHA}->{doc_types_list}, ['Passport',        'National Identity Card'], 'Expected docs for GHA';
    cmp_bag $new_details->{KOR}->{doc_types_list}, [], 'Expected docs for KOR';

    # bump the version
    $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY, 3);
    $redis->del(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'ARG');
    $redis->del(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'GHA');

    $new_details = BOM::Config::Onfido::_get_country_details();
    is $hits, 3, 'new version hit';

    cmp_bag $new_details->{ARG}->{doc_types_list}, [], 'Expected docs for ARG';
    cmp_bag $new_details->{GHA}->{doc_types_list}, [], 'Expected docs for GHA';
    cmp_bag $new_details->{KOR}->{doc_types_list}, [], 'Expected docs for KOR';

    # bump the version
    my %doc_mapping = (
        PPO => 'Passport',
        NIC => 'National Identity Card',
        DLD => 'Driving Licence',
        REP => 'Residence Permit',
        VIS => 'Visa',
        HIC => 'National Health Insurance Card',
        ARC => 'Asylum Registration Card',
        ISD => 'Immigration Status Document',
        VTD => 'Voter Id',
    );

    $redis->set(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY, 4);
    $redis->sadd(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . 'ARG', keys %doc_mapping);

    $new_details = BOM::Config::Onfido::_get_country_details();
    is $hits, 4, 'new version hit';

    cmp_deeply $new_details->{ARG}->{doc_types_list}, [sort values %doc_mapping], 'Expected docs for ARG';

    my @redis_keys = $redis->scan_all(MATCH => +BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_KEY . '*')->@*;
    $redis->del($_) for @redis_keys;

    $redis->del(+BOM::Config::Onfido::ONFIDO_REDIS_CONFIG_VERSION_KEY);
    $mock->unmock_all;
};

done_testing();
