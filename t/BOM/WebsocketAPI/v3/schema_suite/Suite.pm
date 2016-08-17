package Suite;
use strict;
use warnings;
use Test::Most;
use JSON;
use Data::Dumper;

use TestHelper qw/test_schema build_mojo_test/;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::System::RedisReplicated;
use BOM::Platform::Client;
use BOM::Test::Data::Utility::UnitTestDatabase; # we :init later for unit/auth test DBs
use BOM::Test::Data::Utility::AuthTestDatabase;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use RateLimitations qw (flush_all_service_consumers);
use Time::HiRes qw(tv_interval gettimeofday);

# Needs to be at top-level scope since _set_allow_omnibus and _get_stashed need access,
# populated in the main run() loop
my $response;

# Used to allow ->run to happen more than once
my $global_test_iteration = 0;

# Return entire contents of file as string
sub read_file {
    my $path = shift;
    open my $fh, '<:encoding(UTF-8)', $path or die "Could not open $path - $!";
    local $/;
    <$fh>
}

sub run {
    my ($class, $input) = @_;

    # When using remapped email addresses, ensure that each call to ->run increments the counter
    ++$global_test_iteration;

    # Throw away any existing response data - we'll build this up during a ->run session, and
    # need to share it with other subs in this module, but should always start with an empty state.
    undef $response;

    # Start with a clean database
    BOM::Test::Data::Utility::UnitTestDatabase->import(qw(:init));
    BOM::Test::Data::Utility::AuthTestDatabase->import(qw(:init));
    initialize_realtime_ticks_db();

    # Clear existing state for rate limits: verify email in particular
    flush_all_service_consumers();

    { # Pre-populate with a few ticks - they need to be 1s apart
        my $count = 10;
        my $tick_time = time - $count;
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
    }

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

    my $fh = do {
        my $path = 't/BOM/WebsocketAPI/v3/schema_suite/' . $input;
        open my $fh, '<:encoding(UTF-8)', $path or die "Could not open $path - $!";
        $fh
    };

    my $t;
    my $lang = '';
    my ($last_lang, $reset);
    while(my $line = <$fh>) {
        my $counter = $.; # slightly more informative name, for use in log messages at the end of the loop
        chomp $line;
        next if ($line =~ /^(#.*|)$/);

        # arbitrary perl code
        if ($line =~ s/^\[%(.*?)%\]//) {
            eval $1;
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

        my $t0 = [gettimeofday];
        my ($send_file, $receive_file, @template_func) = split(',', $line);

        $send_file =~ /^(.*)\//;
        my $call = $1;

        my $content = read_file('config/v3/' . $send_file);
        $content = _get_values($content, @template_func);

        if ($lang || !$t || $reset) {
            my $new_lang = $lang || $last_lang;
            ok(defined($new_lang), 'have a defined language') or diag "missing [LANG] tag in config before tests?";
            ok(length($new_lang), 'have a valid language') or diag "invalid [LANG] tag in config or broken test?";
            $t         = build_mojo_test({language => $new_lang});
            $last_lang = $new_lang;
            $lang      = '';
            $reset     = '';
        }

        $t = $t->send_ok({json => JSON::from_json($content)})->message_ok;
        my $result = decode_json($t->message->[1]);
        $response->{$call} = $result->{$call};

        $content = read_file('config/v3/' . $receive_file);

        $content = _get_values($content, @template_func);
        _test_schema($receive_file, $content, $result, $fail);
        my $elapsed = tv_interval($t0, [gettimeofday]);
        diag("$input:$counter [$send_file, $receive_file] - ${elapsed}s");
    }
}

sub _get_values {
    my ($content, @template_func) = @_;
    my $c = 0;
    foreach my $f (@template_func) {
        $c++;
        $f =~ s/^\s+|\s+$//g;
        my $template_content;
        if ($f =~ /^\_.*$/) {
            local $@; # ensure we clear this first, to avoid false positive
            $template_content = eval $f;
            # we do not expect any exceptions from the eval, they could indicate
            # invalid Perl code or bug, either way we need to know about them
            ok(!$@, "template content can eval successfully") or
                diag "Possible exception on eval \"$f\": $@" if $@;
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

# responses are stashed in a hash-ref. For example for a sucessful new_account_virtual there will be an new_account_virtual item and there {new_account_virtual}->{oauth_token}
# you can access the stashed values as a template in your test_receive ([_1]) like _get_stashed('new_account_virtual/oauth_token')
# you can also use array index like _get_stashed('api_token/tokens/0/token')
# look at suite.conf for examples
sub _get_stashed {
    my @hierarchy = split '/', shift;

    my $r = $response;

    foreach my $l (@hierarchy) {
        if ($l =~ /^[0-9,.E]+$/) {
            $r = @{$r}[$l];
        } else {
            $r = $r->{$l};
        }
    }

    return $r;
}

# set allow omnibus flag, as it is required for creating new sub account
sub _set_allow_omnibus {
    my @hierarchy = split '/', shift;

    my $r = $response;

    foreach my $l (@hierarchy) {
        if ($l =~ /^[0-9,.E]+$/) {
            $r = @{$r}[$l];
        } else {
            $r = $r->{$l};
        }
    }

    my $client = BOM::Platform::Client->new({loginid => $r});
    $client->allow_omnibus(1);
    $client->save();

    return $r;
}

1;

