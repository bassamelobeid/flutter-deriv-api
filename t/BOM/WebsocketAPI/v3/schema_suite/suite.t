use strict;
use warnings;
use Test::Most;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::System::RedisReplicated;
use BOM::Platform::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use File::Slurp;

initialize_realtime_ticks_db();
build_test_R_50_data();

for my $i (1 .. 10) {
    for my $symbol (qw/R_50 R_100/) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            epoch      => Date::Utility->new->epoch,
            quote      => 100
        });
    }
    sleep 1;
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

my @lines = File::Slurp::read_file('t/BOM/WebsocketAPI/v3/schema_suite/suite.conf');

my $response;
my $counter = 0;

my $t;
my ($lang, $last_lang, $reset) = '';
foreach my $line (@lines) {
    chomp $line;
    $counter++;
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

    my ($send_file, $receive_file, @template_func) = split(',', $line);
    chomp $receive_file;
    diag("\nRunning line $counter [$send_file, $receive_file]\n");

    $send_file =~ /^(.*)\//;
    my $call = $1;

    my $content = File::Slurp::read_file('config/v3/' . $send_file);
    $content = _get_values($content, @template_func);

    if ($lang || !$t || $reset) {
        $t         = build_mojo_test({($lang ne '' ? (language => $lang) : (language => $last_lang))});
        $last_lang = $lang;
        $lang      = '';
        $reset     = '';
    }

    $t = $t->send_ok({json => JSON::from_json($content)})->message_ok;
    my $result = decode_json($t->message->[1]);
    $response->{$call} = $result->{$call};

    $content = File::Slurp::read_file('config/v3/' . $receive_file);

    $content = _get_values($content, @template_func);
    _test_schema($receive_file, $content, $result, $fail);
}

done_testing();

sub _get_values {
    my ($content, @template_func) = @_;
    my $c = 0;
    while (my $f = shift @template_func) {
        $c++;
        $f =~ s/^\s+|\s+$//g;
        my $template_content;
        if ($f =~ /^\_.*$/) {
            $template_content = eval $f;
        } else {
            $f =~ s/^\'|\'$//g;
            $template_content = $f;
        }
        $content =~ s/\[_$c\]/$template_content/mg;
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
