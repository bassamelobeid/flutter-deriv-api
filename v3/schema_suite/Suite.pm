package Suite;
use strict;
use warnings;
use Test::Most;
use JSON;
use Data::Dumper;

use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;
use Test::MockModule;
use YAML::XS qw(LoadFile);
use Scalar::Util;
use Carp;
use File::Spec;

use Cache::RedisDB;
use Sereal::Encoder;

use BOM::Database::Model::OAuth;
use BOM::System::RedisReplicated;
use BOM::Platform::Client;
use BOM::Test::Data::Utility::UnitTestMarketData;    # we :init later for unit/auth test DBs
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Time::HiRes qw(tv_interval gettimeofday);

# Needs to be at top-level scope since _set_allow_omnibus and _get_stashed need access,
# populated in the main run() loop
my $response;

# Used to allow ->run to happen more than once
my $global_test_iteration = 0;

# We don't want to fail due to hiting limits
## no critic (Variables::RequireLocalizedPunctuationVars)
$ENV{BOM_TEST_RATE_LIMITATIONS} = '/home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/rate_limitations.yml';

# Return entire contents of file as string
sub read_file {
    my $path = shift;
    open my $fh, '<:encoding(UTF-8)', $path or die "Could not open $path - $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

my $ticks_inserted;

sub run {
    my ($class, $input) = @_;

    # When using remapped email addresses, ensure that each call to ->run increments the counter
    ++$global_test_iteration;

    # Throw away any existing response data - we'll build this up during a ->run session, and
    # need to share it with other subs in this module, but should always start with an empty state.
    undef $response;

    eval {
        # Start with a clean database
        BOM::Test::Data::Utility::UnitTestMarketData->import(qw(:init));
        BOM::Test::Data::Utility::UnitTestDatabase->import(qw(:init));
        BOM::Test::Data::Utility::AuthTestDatabase->import(qw(:init));
        system(qw(sudo date -s), '2016-08-09 11:59:00') and die "Failed to set date, do we have sudo access? $!";

        initialize_realtime_ticks_db();
        build_test_R_50_data();
        _setup_market_data();

        unless ($ticks_inserted) {
            # Pre-populate with a few ticks - they need to be 1s apart. Note that we insert ticks
            # that are 1..10s in the future here; we'll change the clock a few lines later, so by
            # the time our code is run all these ticks should be in the recent past.
            my $count     = 10;
            my $tick_time = time;
            for my $i (1 .. $count) {
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

    my $stash  = {};
    my $module = Test::MockModule->new('Mojolicious::Controller');
    $module->mock(
        'stash',
        sub {
            my (undef, @params) = @_;
            if (@params > 1 || ref $params[0]) {
                my $values = ref $params[0] ? $params[0] : {@params};
                @$stash{keys %$values} = values %$values;
            }
            Mojo::Util::_stash(stash => @_);
        });

    my (undef, $file_path, undef) = File::Spec->splitpath(__FILE__);
    my @lines = do {
        my $path = $file_path . $input;
        open my $fh, '<:encoding(UTF-8)', $path or die "Could not open $path - $!";
        my @lines = <$fh>;
        close $fh;
        @lines;
    };

    # Track the streaming responses
    my $streams = {};

    my $t;
    my $lang = '';
    my ($last_lang, $reset);

    # Track how long our steps take - we're resetting time so we do this as a sanity
    # check that our clock reset gives us sensible numbers.
    my $cumulative_elapsed = 0;

    # 30s ahead of test start, minus 10 seconds for the initial ticks
    my $reset_time = time + 20;
    my $counter    = 0;
    foreach my $line (@lines) {
        # we are setting the time one second ahead 12:00:00 for every
        # test to ensure time sensitive tests (pricing tests) always start at a consistent time.
        # Note that we have seen problems when resetting the time backwards:
        # symptoms include account balance going negative when buying
        # a contract.
        system(qw(sudo date -s), '@' . $reset_time) and die "Failed to set date, do we have sudo access? $!";
        ++$reset_time;

        ++$counter;    # slightly more informative name, for use in log messages at the end of the loop
        chomp $line;
        next if ($line =~ /^(#.*|)$/);

        # arbitrary perl code
        if ($line =~ s/^\[%(.*?)%\]//) {
            eval $1;    ## no critic
            die $@ if $@;
        }

        if ($line =~ s/^\[(\w+)\]//) {
            $lang = $1;
            next;
        }
        if ($line =~ s/^\{(\w+)\}//) {
            $reset = $1;
            next;
        }

        my $fail;
        if ($line =~ s/^!//) {
            $fail = 1;
        }

        my $start_stream_id;
        if ($line =~ s/^\{start_stream:(.+?)\}//) {
            $start_stream_id = $1;
        }
        my $test_stream_id;
        if ($line =~ s/^\{test_last_stream_message:(.+?)\}//) {
            $test_stream_id = $1;
        }

        my $t0 = [gettimeofday];
        my ($send_file, $receive_file, @template_func);
        if ($test_stream_id) {
            ($receive_file, @template_func) = split(',', $line);
            diag("\nRunning line $counter [$receive_file]\n");
            diag("\nTesting stream [$test_stream_id]\n");
            my $content = read_file($ENV{WEBSOCKET_API_REPO_PATH} . '/config/v3/' . $receive_file);
            $content = _get_values($content, @template_func);
            die 'wrong stream_id' unless $streams->{$test_stream_id};
            my $result = {};
            my @stream_data = @{$streams->{$test_stream_id}->{stream_data} || []};
            $result = $stream_data[-1] if @stream_data;
            _test_schema($receive_file, $content, $result, $fail);
        } else {
            ($send_file, $receive_file, @template_func) = split(',', $line);

            $send_file =~ /^(.*)\//;
            my $call = $1;

            my $content = read_file($ENV{WEBSOCKET_API_REPO_PATH} . '/config/v3/' . $send_file);
            $content = _get_values($content, @template_func);
            my $req_params = JSON::from_json($content);

            die 'wrong stream parameters' if $start_stream_id && !$req_params->{subscribe};
            if ($lang || !$t || $reset) {
                my $new_lang = $lang || $last_lang;
                ok(defined($new_lang), 'have a defined language') or diag "missing [LANG] tag in config before tests?";
                ok(length($new_lang),  'have a valid language')   or diag "invalid [LANG] tag in config or broken test?";
                $t         = build_mojo_test({language => $new_lang}, {}, sub { store_stream_data($streams, @_) });
                $last_lang = $new_lang;
                $lang      = '';
                $reset     = '';
            }

            $t = $t->send_ok({json => $req_params});
            my $i = 0;
            my $result;
            my @subscribed_streams_ids = map { $_->{id} } values %$streams;
            while ($i++ < 5 && !$result) {
                $t->message_ok;
                my $message = decode_json($t->message->[1]);
                # skip subscribed stream's messages
                next
                    if ref $message->{$message->{msg_type}} eq 'HASH'
                    && grep { $message->{$message->{msg_type}}->{id} && $message->{$message->{msg_type}}->{id} eq $_ } @subscribed_streams_ids;
                $result = $message;
            }
            if ($i >= 5) {
                diag("There isn't testing message in last 5 stream messages");
                next;
            }
            $response->{$call} = $result->{$call};

            if ($start_stream_id) {
                my $id = $result->{$call}->{id};
                die 'wrong stream response' unless $id;
                die 'already exists same stream_id' if $streams->{$start_stream_id};
                $streams->{$start_stream_id}->{id}        = $id;
                $streams->{$start_stream_id}->{call_name} = $call;
            }

            $content = read_file($ENV{WEBSOCKET_API_REPO_PATH} . '/config/v3/' . $receive_file);

            $content = _get_values($content, @template_func);
            _test_schema($receive_file, $content, $result, $fail);
        }
        my $elapsed = tv_interval($t0, [gettimeofday]);
        $cumulative_elapsed += $elapsed;

        # Stream ID and/or send_file may be undef
        diag(sprintf "%s:%d [%s] - %.3fs", $input, $counter, join(',', grep { defined } ($test_stream_id, $send_file, $receive_file)), $elapsed);
    }
    diag "Cumulative elapsed time for all steps was ${cumulative_elapsed}s";
    return $cumulative_elapsed;
}

sub _get_values {
    my ($content, @template_func) = @_;
    my $c = 0;
    foreach my $f (@template_func) {
        $c++;
        $f =~ s/^\s+|\s+$//g;
        my $template_content;
        if ($f =~ /^\_.*$/) {
            local $@;    # ensure we clear this first, to avoid false positive
            $template_content = eval $f;    ## no critic

            # we do not expect any exceptions from the eval, they could indicate
            # invalid Perl code or bug, either way we need to know about them
            ok(!$@, "template content can eval successfully")
                or diag "Possible exception on eval \"$f\": $@"
                if $@;
            # note that _get_token may return undef, the template implementation is not advanced
            # enough to support JSON null so we fall back to an empty string
            $template_content //= '';
        } else {
            $f =~ s/^\'|\'$//g;
            $template_content = $f;
        }
        $content =~ s/\[_$c\]/$template_content/g;
    }
    return $content;
}

sub _test_schema {
    my ($schema_file, $content, $data, $fail) = @_;

    my $validator = JSON::Schema->new(JSON::from_json($content));
    my $result    = $validator->validate($data);
    if ($fail) {
        ok(!$result, "$schema_file response is valid while it must fail.");
        if ($result) {
            diag Dumper(\$data);
            diag " - $_" foreach $result->errors;
        }
    } else {
        ok $result, "$schema_file response is valid";
        if (not $result) {
            diag Dumper(\$data);
            diag " - $_" foreach $result->errors;
        }
    }
    return;
}

# fetch the token related to a specific email
# e.g. _get_token('test@binary.com')
sub _get_token {
    my $email  = shift;
    my $redis  = BOM::System::RedisReplicated::redis_read;
    my $tokens = $redis->execute('keys', 'VERIFICATION_TOKEN::*');

    my $code;
    foreach my $key (@{$tokens}) {
        my $value = JSON::from_json($redis->get($key));

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
# you can access the stashed values as a template in your test_receive ([_1]) like _get_stashed('new_account_virtual/oauth_token')
# you can also use array index like _get_stashed('api_token/tokens/0/token')
# look at suite.conf for examples
sub _get_stashed {
    return walk_hierarchy(shift, $response);
}

# set allow omnibus flag, as it is required for creating new sub account
sub _set_allow_omnibus {
    my $r = walk_hierarchy(shift, $response);

    my $client = BOM::Platform::Client->new({loginid => $r});
    $client->allow_omnibus(1);
    $client->save();

    return $r;
}

sub store_stream_data {
    my ($streams, $tx, $result) = @_;
    my $call_name;
    for my $stream_id (keys %$streams) {
        my $stream = $streams->{$stream_id};
        $call_name = $stream->{call_name} if exists $result->{$stream->{call_name}};
    }
    return unless $call_name;
    for my $stream_id (keys %$streams) {
        push @{$streams->{$stream_id}->{stream_data}}, $result
            if $result->{$call_name}->{id} && $result->{$call_name}->{id} eq $streams->{$stream_id}->{id};
    }
    return;
}

sub _setup_market_data {
    my (undef, $file_path, undef) = File::Spec->splitpath(__FILE__);
    my $data = LoadFile($file_path . 'test_data.yml');

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
    my $tick_data = LoadFile($file_path . 'ticks.yml');
    my $encoder   = Sereal::Encoder->new({
        canonical => 1,
    });
    my $redis = Cache::RedisDB->redis;
    for my $key (sort keys %$tick_data) {
        my $ticks = $tick_data->{$key};
        $redis->zadd($key, $_->{epoch}, $encoder->encode($_)) for @$ticks;
    }

    return;
}

1;

