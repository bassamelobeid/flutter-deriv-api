use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;

use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Platform::Utility;
use BOM::User::IdentityVerification;

subtest 'is idv disabled' => sub {
    my %args = (
        country       => 'ng',
        provider      => 'smile_identity',
        document_type => 'drivers_license'
    );
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 1, 'Should return 1 if IDV is disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 0, 'Should return 0 if IDV is enabled');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_countries([qw(ng)]);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 1, 'Should return 1 if IDV country is disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_countries([qw( )]);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 0, 'Should return 0 if IDV country is enabled');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw(smile_identity)]);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 1, 'Should return 1 if IDV provider is disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw( )]);

    BOM::Config::Redis::redis_events()->set(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'smile_identity', 1);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 1, 'Should return 1 if IDV provider is disabled');
    BOM::Config::Redis::redis_events()->del(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'smile_identity');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(ng:drivers_license)]);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 1, 'Should return 1 if IDV document_type is disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(in:drivers_license)]);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 0, 'Should return 0 if IDV document_type is enabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw( )]);

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw(smile_identity:ng:drivers_license)]);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 1, 'Should return 1 if IDV triplet is disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw(smile_identity:ng:nin_slip)]);
    is(BOM::Platform::Utility::is_idv_disabled(%args), 0, 'Should return 0 if IDV document_type is enabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw( )]);

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(zw:national_id)]);
    is(BOM::Platform::Utility::is_idv_disabled('country' => 'zw'), 1, 'Country should be disabled if only supported document is disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw( )]);

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(ng:drivers_license ng:nin_slip ng:passport)]);
    is(BOM::Platform::Utility::is_idv_disabled('country' => 'ng'), 1, 'Country should be disabled if all supported documents are disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw( )]);
};

subtest 'has idv' => sub {
    my %args = (
        country       => 'gh',
        document_type => 'passport'
    );
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    is(BOM::Platform::Utility::has_idv(%args), 0, 'Should return 0 if IDV is disabled and supported');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);
    is(BOM::Platform::Utility::has_idv(%args), 1, 'Should return 1 if IDV is not disabled and supported');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw(smile_identity)]);
    is(BOM::Platform::Utility::has_idv(%args), 1, 'Should return 1 if country, document_type pair has at least one provider');
    BOM::Config::Redis::redis_events()->set(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'identity_pass', 1);
    is(BOM::Platform::Utility::has_idv(%args), 0, 'Should return 0 if country, document_type pair has no provider');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw( )]);
    BOM::Config::Redis::redis_events()->del(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'identity_pass');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw(smile_identity:gh:passport)]);
    is(BOM::Platform::Utility::has_idv(%args), 1, 'Should return 1 if triplet has backup');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw(smile_identity:gh:passport identity_pass:gh:passport)]);
    is(BOM::Platform::Utility::has_idv(%args), 0, 'Should return 0 if all triplets disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw( )]);

    $args{country} = 'xx';
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    is(BOM::Platform::Utility::has_idv(%args), 0, 'Should return 0 if IDV is disabled and not supported');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);
    is(BOM::Platform::Utility::has_idv(%args), 0, 'Should return 0 if IDV is not disabled and not supported');

    delete $args{'document_type'};
    $args{country} = 'gh';
    is(BOM::Platform::Utility::has_idv(%args), 1, 'Should return 1 if IDV is not disabled and supported');
    $args{country} = 'xx';
    is(BOM::Platform::Utility::has_idv(%args), 0, 'Should return 0 if IDV is not disabled and not supported');
};

subtest 'has idv all countries' => sub {
    my %args = (
        country       => 'gh',
        document_type => 'passport'
    );
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{gh}, 0, 'Should return 0 if IDV is disabled and supported');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{gh}, 1, 'Should return 1 if IDV is not disabled and supported');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw(smile_identity)]);
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{gh}, 1, 'Should return 1 if country, document_type pair has at least one provider');
    BOM::Config::Redis::redis_events()->set(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'identity_pass', 1);
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{gh}, 0, 'Should return 0 if country, document_type pair has no provider');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw( )]);
    BOM::Config::Redis::redis_events()->del(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'identity_pass');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw(smile_identity:gh:passport)]);
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{gh}, 1, 'Should return 1 if triplet has backup');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw(smile_identity:gh:passport identity_pass:gh:passport)]);
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{gh}, 0, 'Should return 0 if all triplets disabled');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw( )]);

    $args{country} = 'xx';
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(1);
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{xx}, 0, 'Should return 0 if IDV is disabled and not supported');
    BOM::Config::Runtime->instance->app_config->system->suspend->idv(0);
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{xx}, 0, 'Should return 0 if IDV is not disabled and not supported');

    delete $args{'document_type'};
    $args{country} = 'gh';
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{gh}, 1, 'Should return 1 if IDV is not disabled and supported');
    $args{country} = 'xx';
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{xx}, 0, 'Should return 0 if IDV is not disabled and not supported');

    my %result = %{BOM::Platform::Utility::has_idv_all_countries()};
    is(scalar keys %result, scalar Brands::Countries->new->countries_list->%*, 'Should have resuls for all countries');
    $args{country} = 'xx';
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{gh}, undef, 'Should not have values for other countries');

    %args = (
        country             => 'gh',
        document_type       => 'passport',
        index_with_doc_type => 1
    );
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{"gh"},          1, 'Should return 1 as it is supported');
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{"gh:passport"}, 1, 'Should return 1 as index_with_doc_type is set');

    %args = (
        country       => 'gh',
        document_type => 'passport'
    );
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{"gh"},          1,     'Should return 1 as it is supported');
    is(BOM::Platform::Utility::has_idv_all_countries(%args)->{"gh:passport"}, undef, 'Should return undef as index_with_doc_type is not set');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw(smile_identity:gh:passport identity_pass:gh:passport)]);
    %args = (
        country             => 'gh',
        index_with_doc_type => 1
    );
    my $r = BOM::Platform::Utility::has_idv_all_countries(%args);
    cmp_deeply(
        $r,
        {
            "gh:drivers_license" => 1,
            "gh:voter_id"        => 1,
            gh                   => 1,
            "gh:passport"        => 0,
            "gh:ssnit"           => 1
        },
        'Should show passport as not supported for "gh"'
    );
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_triplets([qw( )]);
};

subtest 'is_idv_selfish' => sub {
    my %args = ();

    throws_ok {
        BOM::Platform::Utility::is_idv_selfish(%args);
    }
    qr/no country/, 'is_idv_selfish dies with "no country" message if no country is provided';

    $args{country} = 'xx';

    throws_ok {
        BOM::Platform::Utility::is_idv_selfish(%args);
    }
    qr/no provider/, 'is_idv_selfish dies with "no provider" message if no provider is provided';

    subtest 'mocked test' => sub {
        my $config_mock     = Test::MockModule->new('BOM::Config');
        my $provider_config = {
            providers => {
                provider_a => {
                    display_name      => 'Provider A',
                    selfish_countries => ['py']
                },
                provider_b => {display_name => 'Provider B'}}};
        $config_mock->mock(
            'identity_verification',
            sub {
                return $provider_config;
            });

        %args = (
            provider => 'provider_a',
            country  => 'py'
        );
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'provider is selfish for specified selfish country';

        $args{provider} = 'provider_b';
        ok !BOM::Platform::Utility::is_idv_selfish(%args), 'provider is not selfish if no specified selfish countries';

        $config_mock->unmock_all;
    };

    subtest 'providers tests' => sub {
        $args{provider} = 'smile_identity';
        ok !BOM::Platform::Utility::is_idv_selfish(%args), 'smile_identity is not selfish';

        $args{provider} = 'zaig';
        $args{country}  = 'br';
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'zaig is selfish for br';
        $args{country} = 'xx';
        ok !BOM::Platform::Utility::is_idv_selfish(%args), 'zaig is not selfish for other countries';

        $args{provider} = 'derivative_wealth';
        ok !BOM::Platform::Utility::is_idv_selfish(%args), 'derivative_wealth is not selfish';

        $args{provider} = 'data_zoo';
        $args{country}  = 'cl';
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'data_zoo is selfish for cl';
        $args{country} = 'id';
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'data_zoo is selfish for id';
        $args{country} = 'in';
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'data_zoo is selfish for in';
        $args{country} = 'pe';
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'data_zoo is selfish for pe';
        $args{country} = 'vn';
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'data_zoo is selfish for vn';
        $args{country} = 'xx';
        ok !BOM::Platform::Utility::is_idv_selfish(%args), 'data_zoo is not selfish for other countries';

        $args{provider} = 'metamap';
        ok !BOM::Platform::Utility::is_idv_selfish(%args), 'metamap is not selfish';

        $args{provider} = 'identity_pass';
        ok !BOM::Platform::Utility::is_idv_selfish(%args), 'identity_pass is not selfish';

        $args{provider} = 'ai_prise';
        $args{country}  = 'bd';
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'ai_prise is selfish for bd';
        $args{country} = 'cn';
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'ai_prise is selfish for cn';
        $args{country} = 'mx';
        ok BOM::Platform::Utility::is_idv_selfish(%args), 'ai_prise is selfish for mx';
        $args{country} = 'xx';
        ok !BOM::Platform::Utility::is_idv_selfish(%args), 'ai_prise is not selfish for other countries';
    };
};

subtest 'idv_configuration' => sub {
    subtest 'force check_for_update' => sub {
        my $forced;
        my $app_config_mock = Test::MockModule->new(ref(BOM::Config::Runtime->instance->app_config));
        $app_config_mock->mock(
            'check_for_update',
            sub {
                my ($self, $force) = @_;
                $forced //= $force;
                return $app_config_mock->original('check_for_update')->(@_);
            });

        $forced = undef;
        BOM::Platform::Utility::idv_configuration();
        ok !$forced, 'by default, force argument is not sent to check_for_update';

        $forced = undef;
        BOM::Platform::Utility::idv_configuration({force_update => 1});
        ok $forced, 'when provided, force argument is sent to check_for_update';

        $app_config_mock->unmock_all();
    };

    subtest 'bogus config' => sub {
        my $countries_mock = Test::MockModule->new('Brands::Countries');
        my $idv_config     = {};
        $countries_mock->mock(
            'get_idv_config',
            sub {
                my (undef, $country) = @_;

                return $idv_config->{$country} if $country;
                return $idv_config;
            });

        my $config = BOM::Platform::Utility::idv_configuration();
        cmp_deeply $config, {}, 'no runtime error for bogus get_idv_config';

        $idv_config = {ke => {}};
        $config     = BOM::Platform::Utility::idv_configuration();
        cmp_deeply $config, {}, 'no runtime error for bogus get_idv_config';

        $idv_config = {ke => {document_types => {}}};
        $config     = BOM::Platform::Utility::idv_configuration();
        cmp_deeply $config, {}, 'no runtime error for bogus get_idv_config';

        $idv_config = {ke => {document_types => {passport => {}}}};
        $config     = BOM::Platform::Utility::idv_configuration();
        cmp_deeply $config, {}, 'no runtime error for bogus get_idv_config';

        $idv_config = {ke => {document_types => {passport => {providers => {}}}}};
        $config     = BOM::Platform::Utility::idv_configuration();
        cmp_deeply $config, {}, 'no runtime error for bogus get_idv_config';

        $idv_config = {ke => {document_types => {passport => {providers => ['provider_a']}}}};

        my $config_mock     = Test::MockModule->new('BOM::Config');
        my $provider_config = {};
        $config_mock->mock(
            'identity_verification',
            sub {
                return $provider_config;
            });

        my $expected = {
            providers => {
                provider_a => {
                    countries => {
                        ke => {
                            documents => {
                                passport => {
                                    enabled    => 1,
                                    is_selfish => 0
                                }}}}}}};

        $config = BOM::Platform::Utility::idv_configuration();
        cmp_deeply $config, $expected, 'no runtime error for bogus identity_verification config';

        $countries_mock->unmock_all();
        $config_mock->unmock_all();
    };

    subtest 'mocked scenarios' => sub {
        my $countries_mock = Test::MockModule->new('Brands::Countries');
        my $idv_config     = {
            ke => {document_types => {passport => {providers => ['provider_a']}}},
            py => {
                document_types => {
                    passport    => {providers => ['provider_a', 'provider_b']},
                    national_id => {providers => ['provider_b']}}
            },
            ng => {document_types => {drivers_license => {providers => ['provider_c']}}}};
        $countries_mock->mock(
            'get_idv_config',
            sub {
                my (undef, $country) = @_;

                return $idv_config->{$country} if $country;
                return $idv_config;
            });

        my $config_mock     = Test::MockModule->new('BOM::Config');
        my $provider_config = {
            providers => {
                provider_a => {
                    display_name      => 'Provider A',
                    selfish_countries => ['ke'],
                },
                provider_b => {
                    display_name      => 'Provider B',
                    selfish_countries => ['py'],
                    additional        => {
                        checks_per_month => 3,
                    }
                },
                provider_c => {
                    display_name => 'Provider C',
                }}};
        $config_mock->mock(
            'identity_verification',
            sub {
                return $provider_config;
            });

        my $config   = BOM::Platform::Utility::idv_configuration();
        my $expected = {
            providers => {
                provider_a => {
                    countries => {
                        ke => {
                            documents => {
                                passport => {
                                    enabled    => 1,
                                    is_selfish => 1
                                }}
                        },
                        py => {
                            documents => {
                                passport => {
                                    enabled    => 1,
                                    has_backup => 1,
                                    is_selfish => 0
                                }}}}
                },
                provider_b => {
                    countries => {
                        py => {
                            documents => {
                                passport => {
                                    enabled    => 1,
                                    has_backup => 1,
                                    is_selfish => 1
                                },
                                national_id => {
                                    enabled    => 1,
                                    is_selfish => 1
                                }}
                        },
                    },
                    additional => {checks_per_month => 3}
                },
                provider_c => {
                    countries => {
                        ng => {
                            documents => {
                                drivers_license => {
                                    enabled    => 1,
                                    is_selfish => 0
                                }}
                        },
                    }}}};
        cmp_deeply $config, $expected, 'expected configuration for enabled providers';

        BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(py:passport)]);
        BOM::Config::Redis::redis_events()->set(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'provider_c', 1);
        $config   = BOM::Platform::Utility::idv_configuration();
        $expected = {
            providers => {
                provider_a => {
                    countries => {
                        ke => {
                            documents => {
                                passport => {
                                    enabled    => 1,
                                    is_selfish => 1
                                }}
                        },
                        py => {
                            documents => {
                                passport => {
                                    enabled    => 0,
                                    is_selfish => 0
                                }}}}
                },
                provider_b => {
                    countries => {
                        py => {
                            documents => {
                                passport => {
                                    enabled    => 0,
                                    is_selfish => 1
                                },
                                national_id => {
                                    enabled    => 1,
                                    is_selfish => 1
                                }}
                        },
                    },
                    additional => {checks_per_month => 3}
                },
                provider_c => {
                    countries => {
                        ng => {
                            documents => {
                                drivers_license => {
                                    enabled    => 0,
                                    is_selfish => 0
                                }}
                        },
                    }}}};
        cmp_deeply $config, $expected, 'expected configuration for disabled document_type';

        BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw( )]);
        BOM::Config::Redis::redis_events()->del(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'provider_c');

        BOM::Config::Redis::redis_events()->set(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'provider_a', 1);
        $config   = BOM::Platform::Utility::idv_configuration();
        $expected = {
            providers => {
                provider_a => {
                    countries => {
                        ke => {
                            documents => {
                                passport => {
                                    enabled    => 0,
                                    is_selfish => 1
                                }}
                        },
                        py => {
                            documents => {
                                passport => {
                                    enabled    => 0,
                                    has_backup => 1,
                                    is_selfish => 0
                                }}}}
                },
                provider_b => {
                    countries => {
                        py => {
                            documents => {
                                passport => {
                                    enabled    => 1,
                                    is_selfish => 1
                                },
                                national_id => {
                                    enabled    => 1,
                                    is_selfish => 1
                                }}
                        },
                    },
                    additional => {checks_per_month => 3}
                },
                provider_c => {
                    countries => {
                        ng => {
                            documents => {
                                drivers_license => {
                                    enabled    => 1,
                                    is_selfish => 0
                                }}
                        },
                    }}}};

        cmp_deeply $config, $expected, 'expected configuration for disabled provider';

        BOM::Config::Redis::redis_events()->del(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'provider_a');

        $countries_mock->unmock_all();
        $config_mock->unmock_all();
    };

    subtest 'test real bundle' => sub {
        my $config   = BOM::Platform::Utility::idv_configuration();
        my $expected = {
            providers => {
                metamap => {
                    countries => {
                        ar => {documents => {dni         => ignore()}},
                        cr => {documents => {national_id => ignore()}},
                        mx => {documents => {curp        => ignore()}},
                        uy => {documents => {national_id => ignore()}}}
                },
                data_zoo => {
                    countries => {
                        in => {
                            documents => {
                                passport        => ignore(),
                                aadhaar         => ignore(),
                                epic            => ignore(),
                                pan             => ignore(),
                                drivers_license => ignore()}
                        },
                        pe => {documents => {national_id => ignore()}},
                        id => {documents => {nik         => ignore()}},
                        cl => {documents => {national_id => ignore()}},
                        vn => {documents => {national_id => ignore()}}}
                },
                derivative_wealth => {countries => {zw => {documents => {national_id => ignore()}}}},
                identity_pass     => {
                    countries => {
                        gh => {
                            documents => {
                                voter_id => ignore(),
                                passport => ignore(),
                                ssnit    => ignore()}
                        },
                        ke => {
                            documents => {
                                national_id => ignore(),
                                passport    => ignore()}}
                    },
                    additional => {checks_per_month => 15000}
                },
                zaig           => {countries => {br => {documents => {cpf => ignore()}}}},
                smile_identity => {
                    countries => {
                        ug => {documents => {national_id_no_photo => ignore()}},
                        za => {documents => {national_id          => ignore()}},
                        gh => {
                            documents => {
                                drivers_license => ignore(),
                                passport        => ignore(),
                                ssnit           => ignore()}
                        },
                        ng => {
                            documents => {
                                nin_slip        => ignore(),
                                drivers_license => ignore()}
                        },
                        ke => {
                            documents => {
                                passport    => ignore(),
                                national_id => ignore(),
                                alien_card  => ignore()}}}
                },
                ai_prise => {
                    countries => {
                        bd => {documents => {national_id => ignore()}},
                        cn => {documents => {national_id => ignore()}},
                        mx => {documents => {curp        => ignore()}}}}}};

        cmp_deeply $config, $expected, 'expected configuration for implemented providers';

        my @expecteds = ({
                enabled    => ignore(),
                is_selfish => ignore(),
                has_backup => 1,
            },
            {
                enabled    => ignore(),
                is_selfish => ignore(),
            });

        foreach my $provider (keys $config->{providers}->%*) {
            my $provider = $config->{providers}->{$provider};
            foreach my $country_code (keys $provider->{'countries'}->%*) {
                my $country_data = $provider->{'countries'}->{$country_code};
                foreach my $document_name (keys $country_data->{'documents'}->%*) {
                    my $document_info = $country_data->{'documents'}->{$document_name};
                    cmp_deeply($document_info,            any(@expecteds), 'valid document type configuration');
                    cmp_deeply($document_info->{enabled}, any((1, 0)),     'valid enabled value');
                }
            }
        }

    };
};

done_testing();

