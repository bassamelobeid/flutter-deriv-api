use strict;
use warnings;
use Test::More;
use Test::Deep;
use Array::Utils qw(array_minus);
use Scalar::Util qw(refaddr);
use BOM::Config;

my $test_parameters = [
    {
        name => 'node.yml',
        args => {
            expected_config => {
                node => {
                    environment      => 'some_env',
                    operation_domain => 'some_domain',
                    roles            => ['some_role'],
                    tags             => ['some_tag']
                },
                feed_server        => {fqdn => '0.0.0.0'},
                local_redis_master => ''
            },
            config => \&BOM::Config::node,
#array_test => ['node|roles','node|tags'] #Optional key. Tests specifed path for array ref values.
        }
    },
    {
        name => 'aes_keys.yml',
        args => {
            expected_config => {
                client_secret_answer => {
                    default_keynum => 1,
                    1              => ''
                },
                client_secret_iv => {
                    default_keynum => 1,
                    1              => ''
                },
                email_verification_token => {
                    default_keynum => 1,
                    1              => ''
                },
                password_counter => {
                    default_keynum => 1,
                    1              => ''
                },
                password_remote => {
                    default_keynum => 1,
                    1              => ''
                },
                payment_agent => {
                    default_keynum => 1,
                    1              => ''
                },
                feeds => {
                    default_keynum => 1,
                    1              => ''
                },
                web_secret => {
                    default_keynum => 1,
                    1              => ''
                }
            },
            config => \&BOM::Config::aes_keys,

        }
    }
];

for my $test_parameter (@$test_parameters){
    subtest "Test YAML return correct structure for $test_parameter->{name}", \&yaml_structure_validator , $test_parameter->{args};
}

sub yaml_structure_validator {
    my $args  = shift;
    my $expected_config = $args->{expected_config};
    my $config = $args->{config}->();
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
    is(scalar @differences_keys,0,'BOM::Config::node returns correct structure');
    # yaml_array_structure_validator($config,$args->{array_test}) if exists($args->{array_test}) ;
}

# sub yaml_array_structure_validator{
#     my $config = shift;
#     my $array_paths = shift;
#     for my $path (@$array_paths){
#         my @keys = split('|',$path);
#         for my $key(@keys)
#     }
# }

subtest 'Test YAML return correct structure for node.yml' => sub {
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
        $config,
        sub {
            push @received_keys, join("|", @_);
        });
    my @expected_keys = ();
    _get_all_paths(
        $expected_node_config,
        sub {
            push @expected_keys, join("|", @_);
        });
    my @differences_keys = array_minus(@expected_keys, @received_keys);
    is(scalar @differences_keys,0,'BOM::Config::node returns correct structure');
    cmp_bag(\@received_keys, \@expected_keys, 'BOM::Config::node returns correct structure');
    is(ref $config->{node}->{roles}, 'ARRAY', 'roles is an array');
};

subtest 'Test YAML return correct structure for aes_keys.yml' => sub {
    my $expected_aes_config = {
        client_secret_answer => {
            default_keynum => 1,
            1              => ''
        },
        client_secret_iv => {
            default_keynum => 1,
            1              => ''
        },
        email_verification_token => {
            default_keynum => 1,
            1              => ''
        },
        password_counter => {
            default_keynum => 1,
            1              => ''
        },
        password_remote => {
            default_keynum => 1,
            1              => ''
        },
        payment_agent => {
            default_keynum => 1,
            1              => ''
        },
        feeds => {
            default_keynum => 1,
            1              => ''
        },
        web_secret => {
            default_keynum => 1,
            1              => ''
        }};
    my $config        = BOM::Config::aes_keys();
    my @received_keys = ();
    _get_all_paths(
        $config,
        sub {
            push @received_keys, join("|", @_);
        });
    my @expected_keys = ();
    _get_all_paths(
        $expected_aes_config,
        sub {
            push @expected_keys, join("|", @_);
        });

    cmp_bag(\@received_keys, \@expected_keys, 'BOM::Config::aes_keys returns correct structure');
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
