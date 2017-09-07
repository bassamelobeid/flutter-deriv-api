package BOM::Test::Suite;
use strict;
use warnings;
use Test::Most;
use JSON;
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
use BOM::Platform::RedisReplicated;
use Client::Account;
use BOM::Test::Data::Utility::UnitTestMarketData;    # we :init later for unit/auth test DBs
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::App;
use Time::HiRes qw(tv_interval gettimeofday);

# Needs to be at top-level scope since _set_allow_omnibus and _get_stashed need access,
# populated in the main run() loop
my $response;

# Used to allow ->run to happen more than once
my $global_test_iteration = 0;

# We don't want to fail due to hiting limits
$ENV{BOM_TEST_RATE_LIMITATIONS} =    ## no critic (Variables::RequireLocalizedPunctuationVars)
    '/home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/rate_limitations.yml';

# all tests start from this date
my $start_date = Date::Utility->new('2016-08-09 11:59:00')->epoch;

# Read entire contents of file as a list of lines
sub read_file_lines {
    my $path = shift;
    open my $fh, '<:encoding(UTF-8)', $path or die "Could not open $path - $!";
    my @lines = <$fh>;
    close $fh;
    return @lines;
}

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
        test_app    => undef,
        placeholder => undef,

        test_app_class    => $args{test_app},
        suite_schema_path => $args{suite_schema_path},
    }, $class;

    return $self;
}

sub set_language {
    my ($self, $lang) = @_;
    $self->{language} = $lang;
    undef $self->{test_app};
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

sub exec_line {
    my ($self, $line, $linenum) = @_;

    # arbitrary perl code
    if ($line =~ s/^\[%(.*?)%\]//) {
        eval $1;    ## no critic (RequireCheckingReturnValueOfEval, ProhibitStringyEval)
        die $@ if $@;
    }

    if ($line =~ s/^\[(\w+)\]//) {
        $self->set_language($1);
        return;
    }
    if ($line =~ s/^\{(\w+)\}//) {
        undef $self->{test_app};
        return;
    }

    # |placeholder=_get_stashed('new_account_real/new_account_real/oauth_token')|
    if ($line =~ s/^\|.*\=(.*)\|$//) {
        my $func = $1;
        local $@;    # ensure we clear this first, to avoid false positive
        $self->{placeholder} = eval $func;    ## no critic (ProhibitStringyEval, RequireCheckingReturnValueOfEval)

        # we do not expect any exceptions from the eval, they could indicate
        # invalid Perl code or bug, either way we need to know about them
        ok(!$@, "template content can eval successfully")
            or diag "Possible exception on eval \"$func\": $@"
            if $@;
        # note that _get_token may return undef, the template implementation is not advanced
        # enough to support JSON null so we fall back to an empty string
        $self->{placeholder} //= '';
        return;
    }

    my $fail;
    if ($line =~ s/^!//) {
        $fail = 1;
    }

    my $test_app = $self->test_app;

    # Finish parsing $line here to keep the test logic separated from it

    my $start_stream_id;
    if ($test_app->is_websocket && $line =~ s/^\{start_stream:(.+?)\}//) {
        $start_stream_id = $1;
    }

    my ($test_stream_id, $send_file, $receive_file, @template_func);
    if ($test_app->is_websocket && $line =~ s/^\{test_last_stream_message:(.+?)\}//) {
        $test_stream_id = $1;
        # there is no $send_file here
        ($receive_file, @template_func) = split(',', $line);
    } else {
        ($send_file, $receive_file, @template_func) = split(',', $line);
    }

    $self->exec_test(
        send_file       => $send_file,
        receive_file    => $receive_file,
        test_stream_id  => $test_stream_id,
        start_stream_id => $start_stream_id,
        template_func   => \@template_func,
        expect_fail     => $fail,
        linenum         => $linenum,
    );
}

sub exec_test {
    my ($self, %args) = @_;

    my $send_file       = $args{send_file};
    my $receive_file    = $args{receive_file} or Carp::croak('Require a receive_file');
    my $test_stream_id  = $args{test_stream_id};
    my $start_stream_id = $args{start_stream_id};
    my $template_func   = $args{template_func};
    my $expect_fail     = $args{expect_fail};
    my $linenum         = $args{linenum};

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
        my $content = $self->read_schema_file($receive_file);
        $content = _get_values($content, $self->{placeholder}, @$template_func);

        $test_app->test_schema_last_stream_message($test_stream_id, $content, $receive_file, $expect_fail);
    } else {
        $send_file =~ /^(.*)\//;
        my $call = $test_app->{call} = $1;

        my $content = $self->read_schema_file($send_file);
        $content = _get_values($content, $self->{placeholder}, @$template_func);
        my $req_params = JSON::from_json($content);

        $req_params = $test_app->adjust_req_params($req_params, {language => $self->{language}});

        die 'wrong stream parameters' if $start_stream_id && !$req_params->{subscribe};

        $content = $self->read_schema_file($receive_file);
        $content = _get_values($content, $self->{placeholder}, @$template_func);

        my $result = $test_app->test_schema($req_params, $content, $receive_file, $expect_fail);
        $response->{$call} = $result;

        if ($start_stream_id) {
            $test_app->start_stream($start_stream_id, $result->{$call}->{id}, $call);
        }
    }
    my $elapsed = tv_interval($t0, [gettimeofday]);
    $self->{cumulative_elapsed} += $elapsed;

    print_test_diag($self->{title}, $linenum, $elapsed, ($test_stream_id || $start_stream_id), $send_file, $receive_file);
}

sub finish {
    my ($self) = @_;

    diag "Cumulative elapsed time for all steps was $self->{cumulative_elapsed}s";
    return $self->{cumulative_elapsed};
}

sub run {
    my ($class, $args) = @_;

    my $path = delete $args->{test_conf_path};
    my ($title) = ($path =~ /\/(.+?)$/);

    my $self = $class->new(
        %$args,
        title => $title,
    );

    my $linenum = 0;
    foreach my $line (read_file_lines($path)) {
        $linenum++;
        chomp $line;
        next if ($line =~ /^(#.*|)$/);

        $self->exec_line($line, $linenum);
    }

    return $self->finish;
}

sub print_test_diag {
    my ($title, $linenum, $elapsed, $stream_id, $send_file, $receive_file) = @_;

    $stream_id = "stream:" . $stream_id if $stream_id;

    # Stream ID and/or send_file may be undef
    diag(sprintf "%s:%d [%s] - %.3fs", $title, $linenum, join(',', grep { defined } ($stream_id, $send_file, $receive_file)), $elapsed);
    return;
}

sub _get_values {
    my ($content, $placeholder_val, @template_func) = @_;
    my $c = 0;
    foreach my $f (@template_func) {
        $c++;
        $f =~ s/^\s+|\s+$//g;
        my $template_content;
        if ($f =~ /^\_.*$/) {
            local $@;    # ensure we clear this first, to avoid false positive
            $template_content = eval $f;    ## no critic (ProhibitStringyEval, RequireCheckingReturnValueOfEval)

            # we do not expect any exceptions from the eval, they could indicate
            # invalid Perl code or bug, either way we need to know about them
            ok(!$@, "template content can eval successfully")
                or diag "Possible exception on eval \"$f\": $@"
                if $@;
            # note that _get_token may return undef, the template implementation is not advanced
            # enough to support JSON null so we fall back to an empty string
            $template_content //= '';
        } elsif ($f eq 'placeholder') {
            $template_content = $placeholder_val;
        } else {
            $f =~ s/^\'|\'$//g;
            $template_content = $f;
        }
        $content =~ s/\[_$c\]/$template_content/g;
    }
    return $content;
}

# fetch the token related to a specific email
# e.g. _get_token('test@binary.com')
sub _get_token {
    my $email  = shift;
    my $redis  = BOM::Platform::RedisReplicated::redis_read;
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
# you can access the stashed values as a template in your test_receive ([_1]) like _get_stashed('new_account_virtual/new_account_virtual/oauth_token')
# you can also use array index like _get_stashed('api_token/api_token/tokens/0/token')
# look at suite.conf for examples
sub _get_stashed {
    return walk_hierarchy(shift, $response);
}

sub _free_gift {
    my ($loginid) = @_;
    my $client = Client::Account->new({loginid => $loginid});
    $client->payment_free_gift(
        currency => 'USD',
        amount   => 10000,
        remark   => 'free gift',
    );
    return;
}

# set allow omnibus flag, as it is required for creating new sub account
sub _set_allow_omnibus {
    my $r = walk_hierarchy(shift, $response);

    my $client = Client::Account->new({loginid => $r});
    $client->allow_omnibus(1);
    $client->save();

    return $r;
}

sub _change_status {
    my ($loginid, $action, $status) = @_;
    my $client = Client::Account->new({loginid => $loginid});
    if ($action eq 'set') {
        $client->set_status($status, 'system', 'for test');
    } else {
        $client->clr_status($status);
    }
    $client->save;
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

    my $redis = BOM::Platform::RedisReplicated::redis_write();
    for my $key (sort keys %$tick_data) {
        my $ticks = $tick_data->{$key};
        $redis->zadd($key, $_->{epoch}, $encoder->encode($_)) for @$ticks;
    }

    return;
}

1;

