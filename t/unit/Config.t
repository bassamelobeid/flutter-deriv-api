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
            array_test => ["node:roles","node:tags"] #Optional key. Tests specifed path for array ref values.
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
    },
    {
        name => 'third_party.yml',
        args => {
            expected_config => {
                auth0 => {
                    client_id => '',
                    client_secret => '',
                    api_uri => ''
                },
                duosecurity => {
                    ikey => '',
                    skey => '',
                    akey => ''
                },
                doughflow => {
                    binary => '',
                    deriv => '',
                    champion => '',
                    passcode => '',
                    environment => ''
                },
                myaffiliates => {
                    user => '',
                    pass => '',
                    host => '',
                    aws_access_key_id => '',
                    aws_secret_access_key => '',
                    aws_bucket => '',
                    aws_region => ''
                },
                oneall => {
                    binary => {
                        public_key => '',
                        private_key => ''
                    },
                    deriv => {
                        public_key => '',
                        private_key => ''
                    }
                },
                proveid => {
                    username => '',
                    password => '',
                    pdf_username => '',
                    pdf_password => '',
                    public_key => '',
                    private_key => '',
                    api_uri => '',
                    api_proxy => '',
                    experian_url => '',
                    uat => {
                        username => '',
                        password => '',
                        public_key => '',
                        private_key => ''
                    }
                },
                bloomberg => {
                    sftp_allowed => '',
                    user => '',
                    password => '',
                    aws => {
                        upload_allowed => '',
                        path => '',
                        bucket => '',
                        profile => '',
                        log => ''
                    }
                },
                qa_duosecurity => {
                    ikey => '',
                    skey => ''
                },
                gamstop => {
                    api_uri => '',
                    batch_uri => '',
                    config => {
                        iom => {
                            api_key => ''
                        },
                        malta => {
                            api_key => ''
                        }
                    }
                },
                elevio => {
                    account_secret => ''
                },
                customerio => {
                    site_id => '',
                    api_key => '',
                    api_token => '',
                    api_uri => ''
                },
                onfido => {
                    authorization_token => '',
                    webhook_token => ''
                },
                smartystreets => {
                    auth_id => '',
                    token => '',
                    licenses => {
                        basic => '',
                        plus => ''
                    },
                    countries => {
                        plus => []
                    }
                },
                segment => {
                    write_key => '',
                    base_uri => ''
                },
                rudderstack => {
                    write_key => '',
                    base_uri => ''
                },
                sendbird => {
                    app_id => '',
                    api_token => ''
                },
                eu_sanctions => {
                    token => ''
                },
                banxa => {
                    api_url => '',
                    api_key => '',
                    api_secret => ''
                },
                wyre => {
                    api_url => '',
                    api_account_id => '',
                    api_secret => ''
                },
                acquired => {
                    company_hashcode => ''
                },
                isignthis => {
                    notification_token => 'some env'
                },
                smile_identity => {
                    api_url => '',
                    partner_id => '',
                    api_key => ''
                },
                zaig => {
                    api_url => '',
                    api_key => ''
                },
                close_io => {
                    api_url => '',
                    api_key => ''
                },
                risk_screen => {
                    api_url => '',
                    api_key => '',
                    port => ''
                },
                cellxperts => {
                    base_uri => 'some env'
                }
            },
            config => \&BOM::Config::third_party,
            array_test => ["smartystreets:countries:plus"]
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
    yaml_array_sub_structure_validator($config,$args->{array_test}) if exists($args->{array_test}) ;
}

sub yaml_array_sub_structure_validator {
    my $config = shift;
    my $array_paths = shift;
    for my $path (@$array_paths){
        my @keys = split(':', $path );
        my $val = $config;
        for my $key(@keys){
            $val = $val->{$key};
        }
        is(ref $val , 'ARRAY',$keys[-1]." is an array");
    }
}



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
