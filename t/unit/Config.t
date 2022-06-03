use strict;
use warnings;
use Test::More;
use Test::Deep;

use Scalar::Util qw(refaddr);
use BOM::Config;

subtest 'Test YAML return correct structure' => sub {
    my $expected_node_config = {
        node => {
            environment      => 'some_env',
            operation_domain => 'some_domain',
            roles            => ['some_role'],
            tags             => ['some_tag']
        },
        feed_server        => {fqdn => '0.0.0.0'},
        local_redis_master => ''
    };
    my $config        = BOM::Config::node();
    my @received_keys = ();
    _get_all_paths(
        $expected_node_config,
        sub {
            my $k1 = shift;
            my $k2 = shift // "";
            push @received_keys, "$k1|$k2";
        });
    my @expected_keys = ();
    _get_all_paths(
        $expected_node_config,
        sub {
            my $k1 = shift;
            my $k2 = shift // "";
            push @expected_keys, "$k1|$k2";
        });

    cmp_deeply(\@received_keys, \@expected_keys, 'BOM::Config::node returns correct structure');

    is(ref $config->{node}->{roles}, 'ARRAY', 'roles is an array');
    is(ref $config->{node}->{tags},  'ARRAY', 'tags is an array');

    # these tests for all configs in BOM::Config.pm
};

subtest 'Config stores state' => sub {
    is(refaddr BOM::Config::node(), refaddr BOM::Config::node(), 'Returns the same object');

    # these tests for all configs in BOM::Config.pm
};

sub _get_all_paths {
    my ($hashref, $code, $args) = @_;
    while (my ($k, $v) = each(%$hashref)) {
        my @newargs = defined($args) ? @$args : ();
        push(@newargs, $k);
        if (ref($v) eq 'HASH') {
            _get_all_paths($v, $code, \@newargs);
        } else {
            $code->(@newargs);
        }
    }
}

done_testing;
