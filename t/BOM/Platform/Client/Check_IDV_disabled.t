use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use Test::MockModule;
use BOM::Platform::Utility;
use BOM::User::IdentityVerification;

use Test::MockObject;

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

        my $expected = {providers => {provider_a => {countries => {ke => {documents => {passport => {enabled => 1}}}}}}};

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
                    display_name => 'Provider A',
                },
                provider_b => {
                    display_name => 'Provider B',
                    additional   => {
                        checks_per_month => 3,
                    }
                },
                provider_c => {display_name => 'Provider C'}}};
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
                        ke => {documents => {passport => {enabled => 1}}},
                        py => {
                            documents => {
                                passport => {
                                    enabled    => 1,
                                    has_backup => 1
                                }}}}
                },
                provider_b => {
                    countries => {
                        py => {
                            documents => {
                                passport => {
                                    enabled    => 1,
                                    has_backup => 1
                                },
                                national_id => {enabled => 1}}
                        },
                    },
                    additional => {checks_per_month => 3}
                },
                provider_c => {
                    countries => {
                        ng => {documents => {drivers_license => {enabled => 1}}},
                    }}}};
        cmp_deeply $config, $expected, 'expected configuration for enabled providers';

        BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(py:passport)]);
        BOM::Config::Redis::redis_events()->set(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'provider_c', 1);
        $config   = BOM::Platform::Utility::idv_configuration();
        $expected = {
            providers => {
                provider_a => {
                    countries => {
                        ke => {documents => {passport => {enabled => 1}}},
                        py => {documents => {passport => {enabled => 0}}}}
                },
                provider_b => {
                    countries => {
                        py => {
                            documents => {
                                passport    => {enabled => 0},
                                national_id => {enabled => 1}}
                        },
                    },
                    additional => {checks_per_month => 3}
                },
                provider_c => {
                    countries => {
                        ng => {documents => {drivers_license => {enabled => 0}}},
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
                        ke => {documents => {passport => {enabled => 0}}},
                        py => {
                            documents => {
                                passport => {
                                    enabled    => 0,
                                    has_backup => 1,
                                }}}}
                },
                provider_b => {
                    countries => {
                        py => {
                            documents => {
                                passport    => {enabled => 1},
                                national_id => {enabled => 1}}
                        },
                    },
                    additional => {checks_per_month => 3}
                },
                provider_c => {
                    countries => {
                        ng => {documents => {drivers_license => {enabled => 1}}},
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
                ai_prise => {countries => {bd => {documents => {national_id => ignore()}}}}}};

        cmp_deeply $config, $expected, 'expected configuration for implemented providers';

        my @expecteds = ({
                enabled    => ignore(),
                has_backup => 1,
            },
            {enabled => ignore()});

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

