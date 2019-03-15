package BOM::Test::Suite;
use strict;
use warnings;
use Test::Most;
use JSON::MaybeXS;
use Data::Dumper;
use BOM::Test::Time qw(set_date);    # should be on top

use BOM::Test::Helper qw/build_test_R_50_data/;
use Test::MockModule;
use YAML::XS qw(LoadFile);
use Scalar::Util;
use Carp;
use File::Spec;
use Capture::Tiny qw(capture);

use Cache::RedisDB;
use Sereal::Encoder;

use BOM::Database::Model::OAuth;
use BOM::Config::RedisReplicated;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestMarketData;    # we :init later for unit/auth test DBs
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase;
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::App;
use Time::HiRes qw(tv_interval gettimeofday);
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;

# populated in the main run() loop
my $response;

# Used to allow ->run to happen more than once
my $global_test_iteration = 0;

# We don't want to fail due to hiting limits
$ENV{BOM_TEST_RATE_LIMITATIONS} =    ## no critic (Variables::RequireLocalizedPunctuationVars)
    '/home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/rate_limitations.yml';

# all tests start from this date
my $start_date = Date::Utility->new('2016-08-09 11:59:00')->epoch;

my $ticks_inserted;

sub new {
    my ($class, %args) = @_;

    # When using remapped email addresses, ensure that each call to ->run increments the counter
    ++$global_test_iteration;

    # Throw away any existing response data - we'll build this up during a ->run session, and
    # need to share it with other subs in this module, but should always start with an empty state.
    undef $response;

    eval {
        # Start with a clean database
        BOM::Test::Data::Utility::FeedTestDatabase->import(qw(:init));
        BOM::Test::Data::Utility::UnitTestMarketData->import(qw(:init));
        BOM::Test::Data::Utility::UnitTestDatabase->import(qw(:init));
        BOM::Test::Data::Utility::AuthTestDatabase->import(qw(:init));
        set_date($start_date);

        initialize_realtime_ticks_db();
        build_test_R_50_data();
        _setup_market_data();

        unless ($ticks_inserted) {
            # Pre-populate with a few ticks - they need to be 1s apart. Note that we insert ticks
            # that are 1..10s in the future here; we'll change the clock a few lines later, so by
            # the time our code is run all these ticks should be in the recent past.
            my $count     = 10;
            my $tick_time = time;
            for (1 .. $count) {
                for my $symbol (qw/R_50 R_100/) {
                    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                        underlying => $symbol,
                        epoch      => $tick_time,
                        quote      => 100
                    });
                }
                ++$tick_time;
            }

            # We only do this once
            $ticks_inserted = 1;
        }
        1;
    } or do {
        # Report on the failure for tracing
        diag Carp::longmess("Test setup failure - $@");
        BAIL_OUT($@);
    };

    my $self = bless {
        title => $args{title},

        # The current language
        language => '',

        # Track how long our steps take - we're resetting time so we do this as a sanity
        # check that our clock reset gives us sensible numbers.
        cumulative_elapsed => 0,

        # 30s ahead of test start, minus 10 seconds for the initial ticks
        # we cannot rely on time here, previous jobs can take different number of seconds
        reset_time => $start_date + 20,

        # TODO(leonerd): what are these for?
        test_app => undef,

        test_app_class    => $args{test_app},
        suite_schema_path => $args{suite_schema_path},
    }, $class;

    return $self;
}

sub reset_app {
    my ($self) = @_;
    undef $self->{test_app};
    return;
}

sub set_language {
    my ($self, $lang) = @_;
    $self->{language} = $lang;
    undef $self->{test_app};
    return;
}

sub test_app {
    my ($self) = @_;
    return $self->{test_app} //= do {
        my $lang = $self->{language};
        ok(defined($lang), 'have a defined language') or diag "missing [LANG] tag in config before tests?";
        ok(length($lang),  'have a valid language')   or diag "invalid [LANG] tag in config or broken test?";

        my $test_app = BOM::Test::App->new({
                language => $lang,
                app      => $self->{test_app_class}});
        $test_app->{language} = $lang;
        $test_app;
    };
}

sub read_schema_file {
    my ($self, $relpath) = @_;
    my $path = $self->{suite_schema_path} . $relpath;

    open my $fh, '<:encoding(UTF-8)', $path or die "Could not open $path - $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub read_templated_schema_file {
    my ($self, $relpath, %args) = @_;

    my @template_values = @{$args{template_values} // []};

    my $content = $self->read_schema_file($relpath);

    # TODO(leonerd): use 'my sub ...' when we can use 5.18+
    my $expand = sub {
        my ($idx) = @_;

        return $template_values[$idx - 1] if defined $template_values[$idx - 1];

        warn "No template value defined for template parameter [_$idx]";
        return "[MISSING VALUE FOR PARAMETER $idx]";
    };

    # Expand templates in the form [_nnn] by using the functions given in
    # @$template_values.
    $content =~ s{\[_(\d+)\]}{$expand->($1)}eg;

    return $content;
}

# Some helper methods that might be useful from test scripts to generate template parameters

# fetch the token related to a specific email
# e.g. $suite->get_token('test@binary.com')
sub get_token {
    my ($self, $email) = @_;
    return _get_token($email) // '';    # never return 'undef'
}

# fetch a stashed value from a previous response
sub get_stashed {
    my ($self, $path) = @_;
    return _get_stashed($path) // "";
}

sub change_status {
    my ($self, $loginid, $action, $status) = @_;
    _change_status($loginid, $action, $status);
    return;
}

sub free_gift {
    my ($self, $loginid, $currency, $amount) = @_;
    _free_gift($loginid, $currency, $amount);
    return;
}

sub exec_test {
    my ($self, %args) = @_;

    my $send_file       = $args{send_file};
    my $receive_file    = $args{receive_file} or Carp::croak('Require a receive_file');
    my $test_stream_id  = $args{test_stream_id};
    my $start_stream_id = $args{start_stream_id};
    my $expect_fail     = $args{expect_fail};
    my $linenum         = $args{linenum};
    # plus 'template_values'

    # we are setting the time two seconds ahead for every step to ensure time
    # sensitive tests (pricing tests) always start at a consistent time.
    # Note that we have seen problems when resetting the time backwards:
    # symptoms include account balance going negative when buying
    # a contract.
    set_date($self->{reset_time});
    $self->{reset_time} += 2;

    my $test_app = $self->test_app;

    my $t0 = [gettimeofday];
    if ($test_stream_id) {
        my $content = $self->read_templated_schema_file(
            $receive_file,
            template_values => $args{template_values},
        );

        $test_app->test_schema_last_stream_message($test_stream_id, $content, $receive_file, $expect_fail);
    } else {
        $send_file =~ /^(.*)\//;
        my $call = $test_app->{call} = $1;

        my $content = $self->read_templated_schema_file(
            $send_file,
            template_values => $args{template_values},
        );
        my $req_params = JSON::MaybeXS->new->decode($content);

        $req_params = $test_app->adjust_req_params($req_params, {language => $self->{language}});

        die 'wrong stream parameters' if $start_stream_id && !$req_params->{subscribe};

        $content = $self->read_templated_schema_file(
            $receive_file,
            template_values => $args{template_values},
        );

        my $result = $test_app->test_schema($req_params, $content, $receive_file, $expect_fail);
        $response->{$call} = $result;

        if ($start_stream_id) {
            $test_app->start_stream($start_stream_id, $result->{$call}->{id}, $call);
        }
    }
    my $elapsed = tv_interval($t0, [gettimeofday]);
    $self->{cumulative_elapsed} += $elapsed;

    print_test_diag($self->{title}, $linenum, $elapsed, ($test_stream_id || $start_stream_id), $send_file, $receive_file);

    return;
}

sub finish {
    my ($self) = @_;

    diag "Cumulative elapsed time for all steps was $self->{cumulative_elapsed}s";
    return $self->{cumulative_elapsed};
}

sub print_test_diag {
    my ($title, $linenum, $elapsed, $stream_id, $send_file, $receive_file) = @_;

    $stream_id = "stream:" . $stream_id if $stream_id;

    # Stream ID and/or send_file may be undef
    diag(sprintf "%s:%d [%s] - %.3fs", $title, $linenum, join(',', grep { defined } ($stream_id, $send_file, $receive_file)), $elapsed);
    return;
}

# fetch the token related to a specific email
# e.g. _get_token('test@binary.com')
sub _get_token {
    my $email  = shift;
    my $redis  = BOM::Config::RedisReplicated::redis_read;
    my $tokens = $redis->execute('keys', 'VERIFICATION_TOKEN::*');

    my $code;
    foreach my $key (@{$tokens}) {
        my $value = JSON::MaybeXS->new->decode(Encode::decode_utf8($redis->get($key)));

        if ($value->{email} eq $email) {
            $key =~ /^VERIFICATION_TOKEN::(\w+)$/;
            $code = $1;
            last;
        }
    }
    return $code;
}

# Given a path like /some/nested/0/structure/4/here,
# return $data->{some}{nested}[0]{structure}[4]{here}.
# See also: L<Data::Visitor>, L<Data::Walker>
sub walk_hierarchy {
    my ($path, $data) = @_;
    $data = Scalar::Util::looks_like_number($_) ? $data->[$_] : $data->{$_} for split qr{/}, $path;
    return $data;
}

# responses are stashed in a hash-ref. For example for a sucessful new_account_virtual there will be an new_account_virtual item and there {new_account_virtual}->{oauth_token}
# you can access the stashed values as a template in your test_receive ([_1]) like _get_stashed('new_account_virtual/new_account_virtual/oauth_token')
# you can also use array index like _get_stashed('api_token/api_token/tokens/0/token')
# look at suite.conf for examples
sub _get_stashed {
    return walk_hierarchy(shift, $response);
}

sub _free_gift {
    my ($loginid, $currency, $amount) = @_;
    $currency ||= 'USD';
    $amount   ||= '10000';
    my $client = BOM::User::Client->new({loginid => $loginid});
    $client->payment_free_gift(
        currency => $currency,
        amount   => $amount,
        remark   => 'free gift',
    );
    return;
}

sub _change_status {
    my ($loginid, $action, $status) = @_;
    my $client = BOM::User::Client->new({loginid => $loginid});
    if ($action eq 'set') {
        $client->status->set($status, 'system', 'for test');
    } else {
        $client->status->clear($status);
    }
    return;
}

sub _setup_market_data {
    my $data = LoadFile('/home/git/regentmarkets/bom-test/data/suite_market_data.yml');

    foreach my $d (@$data) {
        my $key = delete $d->{name};
        $d->{recorded_date} = Date::Utility->new;
        BOM::Test::Data::Utility::UnitTestMarketData::create_doc($key, $d);
    }

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'correlation_matrix',
        {
            recorded_date  => Date::Utility->new,
            'correlations' => {
                'FCHI' => {
                    'GBP' => {
                        '12M' => 0.307,
                        '3M'  => 0.356,
                        '6M'  => 0.336,
                        '9M'  => 0.32,
                    },
                    'USD' => {
                        '12M' => 0.516,
                        '3M'  => 0.554,
                        '6M'  => 0.538,
                        '9M'  => 0.525,
                        }

                }}});

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            events => [{
                    release_date => Date::Utility->new->minus_time_interval('5d')->epoch,
                    event_name   => 'test',
                    symbol       => 'FAKE',
                    impact       => 1,
                    source       => 'fake source'
                }]});

    # only populating aggregated ticks for frxUSDJPY
    my $tick_data = LoadFile('/home/git/regentmarkets/bom-test/data/suite_ticks.yml');
    my $encoder   = Sereal::Encoder->new({
        canonical => 1,
    });

    my $redis = BOM::Config::RedisReplicated::redis_write();
    for my $key (sort keys %$tick_data) {
        my $ticks = $tick_data->{$key};
        $redis->zadd($key, $_->{epoch}, $encoder->encode($_)) for @$ticks;
    }

    for my $d (grep { $_->{symbol} && $_->{symbol} =~ /^frx/ } @$data) {
        BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($d->{symbol}, Date::Utility->new);
    }

    populate_exchange_rates();
    return;
}

1;

