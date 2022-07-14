package YamlTestStructure;

use 5.010;
use strict;
use warnings;
use Scalar::Util qw(refaddr);
use Test::More;
use Test::Deep qw(cmp_bag);
use Array::Utils qw(array_minus);
use B qw(svref_2object);


sub yaml_structure_validator {
    my $args            = shift;
    my $expected_config = $args->{expected_config};
    my $config          = $args->{config}->();
    my $file_is_array   = $args->{file_is_array};
    my $function        = svref_2object($args->{config})->GV;
    diag($file_is_array) if (exists $args->{file_is_array});
    if (!$file_is_array) {
        my @received_keys = ();
        _get_all_paths(
            $config,
            sub {
                push @received_keys, join("|", @_);
            });
        my @expected_keys = ();
        _get_all_paths(
            $expected_config,
            sub {
                push @expected_keys, join("|", @_);
            });
        my @differences_keys = array_minus(@expected_keys, @received_keys);
        cmp_bag(\@differences_keys, [], $function->NAME . ' returns correct structure');
        _yaml_array_sub_structure_validator($config, $args->{array_test}) if exists($args->{array_test});
    } else {
        die "Test specified config is array but it was found to be non array!" unless ref($config) eq 'ARRAY';
        for my $line (@$config) {
            die "not hashref" unless ref($line) eq 'HASH';
            my @received_keys = ();
            _get_all_paths(
                $line,
                sub {
                    push @received_keys, join("|", @_);
                });
            my @expected_keys = ();
            _get_all_paths(
                $expected_config->[0],
                sub {
                    push @expected_keys, join("|", @_);
                });
            my @differences_keys = array_minus(@expected_keys, @received_keys);
            is(scalar @differences_keys, 0, $function->NAME . ' returns correct structure');
            _yaml_array_sub_structure_validator($line, $args->{array_test}) if exists($args->{array_test});
        }
    }
}

sub _yaml_array_sub_structure_validator {
    my $config      = shift;
    my $array_paths = shift;
    for my $path (@$array_paths) {
        my @keys = split(':', $path);
        my $val  = $config;
        for my $key (@keys) {
            $val = $val->{$key};
        }
        is(ref $val, 'ARRAY', $keys[-1] . " is an array");
    }
}

sub _get_all_paths {
    my ($hashref, $code, $args) = @_;
    while (my ($k, $v) = each(%$hashref)) {
        my @newargs = defined($args) ? @$args : ();
        if (ref($v) eq 'ARRAY') {
            push(@newargs, $k);
            for my $e (@$v) {
                _get_all_paths($e, $code, \@newargs) if (ref($e) eq 'HASH');
            }
        } else {
            push(@newargs, $k);
        }
        if (ref($v) eq 'HASH') {
            _get_all_paths($v, $code, \@newargs);
        } else {
            $code->(@newargs);
        }
    }
}

1;

