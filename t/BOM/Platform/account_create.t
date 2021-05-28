use strict;
use warnings;
use Test::MockTime::HiRes;
use Guard;
use JSON::MaybeXS;
use Date::Utility;

use Test::More (tests => 4);
use Test::Exception;
use Test::Warn;
use Test::MockModule;
use Test::Warnings;

use BOM::User::Client;
use BOM::User::FinancialAssessment qw(decode_fa);
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Config;

#required for validate_account_details
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $on_production = 1;
my $config_mocked = Test::MockModule->new('BOM::Config');
$config_mocked->mock('on_production', sub { return $on_production });

my $idauth_mocked = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
$idauth_mocked->mock(
    'run_validation',
    sub {
        return 1;
    });

my $vr_acc;
lives_ok {
    $vr_acc = create_vr_acc({
        email           => 'foo+us@binary.com',
        client_password => 'foobar',
        residence       => 'us',                  # US
    });
}
'create VR acc';
is($vr_acc->{error}->{code}, 'invalid residence', 'create VR acc failed: restricted country');

$on_production = 0;

my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $vr_details = {
    CR => {
        email              => 'foo+id@binary.com',
        client_password    => 'foobar',
        residence          => 'id',                  # Indonesia
        address_state      => 'BA',
        salutation         => 'Ms',
        myaffiliates_token => 'this is token',
        email_consent      => 0,
        lc_email_consent   => 1,
    },
    MLT => {
        email              => 'foo+nl@binary.com',
        client_password    => 'foobar',
        residence          => 'nl',                  # Netherlands
        address_state      => '',
        salutation         => 'Mr',
        myaffiliates_token => 'this is token',
        email_consent      => 1,
        lc_email_consent   => 0,
    },
    MX => {
        email              => 'foo+gb@binary.com',
        client_password    => 'foobar',
        residence          => 'gb',                  # UK
        address_state      => 'BIR',
        salutation         => 'Mrs',
        myaffiliates_token => 'this is token',
        email_consent      => 1,
        lc_email_consent   => 0,
    },
};

my %real_client_details = (
    salutation                    => 'Ms',
    last_name                     => 'binary',
    date_of_birth                 => '1990-01-01',
    address_line_1                => 'address 1',
    address_line_2                => 'address 2',
    address_city                  => 'city',
    address_state                 => '',
    address_postcode              => '89902872',
    phone                         => '+622112345678',
    secret_question               => 'Mother\'s maiden name',
    secret_answer                 => 'sjgjdhgdjgdj',
    myaffiliates_token_registered => 0,
    checked_affiliate_exposures   => 0,
    latest_environment            => '',
    account_opening_reason        => 'Hedging',
    non_pep_declaration_time      => Date::Utility->new()->_plus_years(1)->date_yyyymmdd,
);

my %financial_data = (
    forex_trading_experience             => '0-1 year',
    forex_trading_frequency              => '0-5 transactions in the past 12 months',
    binary_options_trading_experience    => '0-1 year',
    binary_options_trading_frequency     => '0-5 transactions in the past 12 months',
    cfd_trading_experience               => '0-1 year',
    cfd_trading_frequency                => '0-5 transactions in the past 12 months',
    other_instruments_trading_experience => '0-1 year',
    other_instruments_trading_frequency  => '0-5 transactions in the past 12 months',
    employment_industry                  => 'Finance',
    education_level                      => 'Secondary',
    income_source                        => 'Self-Employed',
    net_income                           => '$50,001 - $100,000',
    estimated_worth                      => '$250,001 - $500,000',
    occupation                           => 'Managers',
    employment_status                    => "Self-Employed",
    source_of_wealth                     => "Company Ownership",
    account_turnover                     => '$50,001 - $100,000',
);

subtest 'create account' => sub {
    foreach my $broker (keys %$vr_details) {
        my ($real_acc, $vr_client, $real_client, $user);
        lives_ok {
            my $vr_acc = create_vr_acc($vr_details->{$broker});
            ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
            is($vr_client->myaffiliates_token, 'this is token',                         'myaffiliates token ok');
            is($user->email_consent,           $vr_details->{$broker}->{email_consent}, 'email consent ok');
        }
        'create VR acc';

        # real acc
        lives_ok {
            $real_acc = create_real_acc($vr_client, $user, $broker);
            ($real_client, $user) = @{$real_acc}{'client', 'user'};
        }
        "create $broker acc OK, after verify email";
        is($real_client->broker, $broker, 'Successfully create ' . $real_client->loginid);
        # test account_opening_reason
        is($real_client->account_opening_reason, $real_client_details{account_opening_reason}, "Account Opening Reason should be the same");
        is($real_client->user->email_consent,    $vr_details->{$broker}->{email_consent},      'email consent ok');

        # MF acc
        if ($broker eq 'MLT' or $broker eq 'MX') {
            $real_client->status->set('age_verification', 'system', 'test');

            lives_ok { $real_acc = create_mf_acc($real_client, $user); } "create MF acc";
            is($real_acc->{client}->broker, 'MF', "Successfully create " . $real_acc->{client}->loginid);
            my $cl   = BOM::User::Client->new({loginid => $real_acc->{client}->loginid});
            my $data = decode_fa($cl->financial_assessment());
            is $data->{forex_trading_experience}, '0-1 year', "got the forex trading experience";
        }

        # Prepare for the email_consent-less test
        $vr_details->{$broker}->{email} = 'test_' . $vr_details->{$broker}->{email};
        delete $vr_details->{$broker}->{email_consent};
    }

    foreach my $broker (keys %$vr_details) {
        my ($real_acc, $vr_client, $real_client, $user);
        lives_ok {
            my $vr_acc = create_vr_acc($vr_details->{$broker});
            ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
            is($vr_client->myaffiliates_token, 'this is token',                            'myaffiliates token ok');
            is($user->email_consent,           $vr_details->{$broker}->{lc_email_consent}, 'default email consent from LC is ok');
        }
        'create VR acc';

        # real acc
        lives_ok {
            $real_acc = create_real_acc($vr_client, $user, $broker);
            ($real_client, $user) = @{$real_acc}{'client', 'user'};
        }
        "create $broker acc OK, after verify email";
        is($real_client->broker,              $broker,                                    'Successfully create ' . $real_client->loginid);
        is($real_client->user->email_consent, $vr_details->{$broker}->{lc_email_consent}, 'default email consent from LC is ok');
    }

    # test create account in 2016-02-29
    set_absolute_time(1456724000);
    my $guard = guard { restore_time };

    my $broker       = 'CR';
    my %t_vr_details = (
        %{$vr_details->{CR}},
        email => 'foo+nobug@binary.com',
    );
    my ($vr_client, $user, $real_acc, $real_client, $vr_acc);
    lives_ok {
        $vr_acc = create_vr_acc(\%t_vr_details);
        ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
    }
    'create VR acc';

    # create virtual wallet client
    my ($vr_wallet_client, $user_wallet, $vr_wallet_acc);
    lives_ok {
        $vr_wallet_acc = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email => 'foo+noresidence@binary.com',
                },
                type => 'wallet'
            });
        ($vr_wallet_client, $user_wallet) = @{$vr_wallet_acc}{'client', 'user'};

    }
    'create VR wallet account';

    is($vr_wallet_client->payment_method, 'VirtualMoney', 'correct payment_method for virtual wallet');

    my %t_details = (
        %real_client_details,
        residence       => $t_vr_details{residence},
        broker_code     => $broker,
        first_name      => 'foonobug',
        client_password => $vr_client->password,
        email           => $t_vr_details{email});

    # create virtual without residence and password
    lives_ok {
        my $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email => 'foo+noresidence@binary.com',
                }});
        my ($vr_client_n, $user_n) = @{$vr_acc}{'client', 'user'};
    }
    'create VR acc without residence and password';

    subtest virtual_company_for_brand => sub {
        my %expected = (
            binary   => 'virtual',
            deriv    => 'virtual',
            champion => 'champion-virtual',
        );

        for my $brand_name (sort keys %expected) {
            is(BOM::Platform::Account::Virtual::_virtual_company_for_brand($brand_name, 'trading')->short,
                $expected{$brand_name}, "Got correct virtual company for $brand_name brand");
        }

        my %expected_wallet_company = (
            binary => 'samoa-virtual',
            deriv  => 'samoa-virtual',
        );

        for my $brand_name (sort keys %expected_wallet_company) {
            is(
                BOM::Platform::Account::Virtual::_virtual_company_for_brand($brand_name, 'wallet')->short,
                $expected_wallet_company{$brand_name},
                "Got correct virtual wallet company for $brand_name brand"
            );
        }

        ok !BOM::Platform::Account::Virtual::_virtual_company_for_brand('INVALID_BRAND'), 'Invalid brand';
    };

    subtest date_first_contact => sub {
        my $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo1+datecontact@binary.com',
                    date_first_contact => Date::Utility->today->plus_time_interval('1d')->date_yyyymmdd
                }});
        is($vr_acc_n->{user}->date_first_contact, '2016-02-29', 'Date in future set to today');

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo5+datecontact@binary.com',
                    date_first_contact => '2016-13-40'
                }});
        is($vr_acc_n->{user}->date_first_contact, '2016-02-29', 'Invalid date gets set to today');

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo2+datecontact@binary.com',
                    date_first_contact => Date::Utility->today->date_yyyymmdd
                }});
        isa_ok($vr_acc_n->{client}, 'BOM::User::Client', 'No error when today');

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo3+datecontact@binary.com',
                    date_first_contact => Date::Utility->today->minus_time_interval('40d')->date_yyyymmdd
                }});
        is($vr_acc_n->{user}->date_first_contact, '2016-01-30', 'When over 30 days old date_first_contact is 30 days old');

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo4+datecontact@binary.com',
                    date_first_contact => Date::Utility->today->minus_time_interval('20d')->date_yyyymmdd
                }});
        isa_ok($vr_acc_n->{client}, 'BOM::User::Client', 'No error when under 30 days old ');
    };

    $t_details{place_of_birth} = 'xx';
    my $details = BOM::Platform::Account::Real::default::validate_account_details(\%t_details, $vr_client, $broker, 1);
    is $details->{error}, 'InvalidPlaceOfBirth', 'invalid place of birth returns correct error';

    delete $t_details{phone};
    $t_details{place_of_birth} = '';
    $details = BOM::Platform::Account::Real::default::validate_account_details(\%t_details, $vr_client, $broker, 1);
    is $details->{error}, 'TooLateNonPepTime', 'Non-pep declaratin time is too late';
    $t_details{non_pep_declaration_time} = Date::Utility->today->date_yyyymmdd;

    $details = BOM::Platform::Account::Real::default::validate_account_details(\%t_details, $vr_client, $broker, 1);
    is $details->{error}, undef, 'no error for empty place of birth';

    # Invalid phone
    $t_details{phone} = '+623234234234777a';
    $details = BOM::Platform::Account::Real::default::validate_account_details(\%t_details, $vr_client, $broker, 1);
    is $details->{error}, 'InvalidPhone', 'Invalid phone';

    $details = BOM::Platform::Account::Real::default::validate_account_details({%t_details, phone => ''}, $vr_client, $broker, 1);
    is $details->{error}, undef, 'no error for empty phone';

    $details = BOM::Platform::Account::Real::default::validate_account_details({
            %t_details,
            phone => undef,
        },
        $vr_client,
        $broker, 1
    );
    is $details->{error}, undef, 'no error for undef phone';

    $details = BOM::Platform::Account::Real::default::validate_account_details({
            %t_details,
            phone => '123456789',
        },
        $vr_client,
        $broker, 1
    );
    is $details->{error}, undef, 'no error for 123456789 phone';

    $t_details{phone} = sprintf("+15417555%03d", rand(999));

    # real acc
    lives_ok {
        $real_acc = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            details     => \%t_details,
            country     => $vr_client->residence,
        });
        ($real_client, $user) = @{$real_acc}{'client', 'user'};
    }
    "create $broker acc OK, after verify email";
    is($real_client->broker, $broker, 'Successfully create ' . $real_client->loginid);

    subtest 'gender from salutation' => sub {
        my $expected = ($vr_details->{$broker}->{salutation} eq 'Mr') ? 'm' : 'f';
        is($real_client->gender, $expected, "$vr_details->{$broker}->{salutation} is $expected");
    };

    # mock virtual account with social signup flag
    foreach my $broker_code (keys %$vr_details) {
        my %social_login_user_details = (
            %{$vr_details->{$broker_code}},
            email         => 'social+' . $broker_code . '@binary.com',
            social_signup => 1,
        );
        my ($vr_client, $real_client, $social_login_user, $real_acc);
        lives_ok {
            my $vr_acc = create_vr_acc(\%social_login_user_details);
            ($vr_client, $social_login_user) = @{$vr_acc}{qw/client user/};
        }
        'create VR account';

        is($social_login_user->{has_social_signup}, 1, 'social login user has social signup flag');
        $real_client_details{phone} = sprintf("+15417123%03d", rand(999));

        my %details = (
            %real_client_details,
            residence       => $social_login_user_details{residence},
            broker_code     => $broker_code,
            first_name      => 'foo+' . $broker_code,
            client_password => $vr_client->password,
            email           => $social_login_user_details{email},
        );
        # real acc
        # MF social login user is able to create client account
        if ($broker_code eq 'MF') {
            lives_ok {
                my $params = \%financial_data;
                $params->{accept_risk} = 1;
                $real_acc = BOM::Platform::Account::Real::maltainvest::create_account({
                    from_client => $vr_client,
                    user        => $social_login_user,
                    details     => \%details,
                    country     => $vr_client->residence,
                    params      => $params,
                });
            }
            "create $broker_code account OK, after verify email";
        } elsif ($broker_code eq 'MX') {
            lives_ok {
                $real_acc = BOM::Platform::Account::Real::default::create_account({
                    from_client => $vr_client,
                    user        => $social_login_user,
                    details     => \%details,
                    country     => $vr_client->residence,
                });
            }
            "create $broker_code account OK, after verify email";
        } else {
            # Social login user may create default account
            lives_ok {
                $real_acc = BOM::Platform::Account::Real::default::create_account({
                    from_client => $vr_client,
                    user        => $social_login_user,
                    details     => \%details,
                    country     => $vr_client->residence,
                });
            }
            "create $broker_code account OK, after verify email";
        }

        my ($client, $user) = @{$real_acc}{qw/client user/};
        is(defined $user,   1,            "Social login user with residence $user->residence has been created");
        is($client->broker, $broker_code, "Successfully created real account $client->loginid");
    }

    subtest 'Empty phone number' => sub {
        foreach my $broker_code (keys %$vr_details) {
            my %empty_phone_number_details = (
                %{$vr_details->{$broker_code}},
                email         => 'empty_phone+' . $broker_code . '@binary.com',
                phone         => '',
                social_signup => 1,
            );
            my ($vr_client, $real_client, $empty_phone_login_user, $real_acc);
            lives_ok {
                my $vr_acc = create_vr_acc(\%empty_phone_number_details);
                ($vr_client, $empty_phone_login_user) = @{$vr_acc}{qw/client user/};
            }
            'create VR account';

            my %details = (
                %real_client_details,
                residence       => $empty_phone_number_details{residence},
                broker_code     => $broker_code,
                first_name      => 'emptyness+' . $broker_code,
                client_password => $vr_client->password,
                email           => $empty_phone_number_details{email},
            );

            lives_ok {
                $real_acc = BOM::Platform::Account::Real::default::create_account({
                    from_client => $vr_client,
                    user        => $empty_phone_login_user,
                    details     => \%details,
                    country     => $vr_client->residence,
                });
            }
            "create $broker_code account OK";

            my $mf_acc;
            if ($broker_code eq 'MX' || $broker_code eq 'MLT') {
                lives_ok {
                    my $params = \%financial_data;
                    $details{broker_code}  = 'MF';
                    $params->{accept_risk} = 1;
                    $mf_acc                = BOM::Platform::Account::Real::maltainvest::create_account({
                        from_client => $vr_client,
                        user        => $empty_phone_login_user,
                        details     => \%details,
                        country     => $vr_client->residence,
                        params      => $params,
                    });
                }
                "create MF account OK";
            }

            my ($client) = @{$real_acc}{qw/client/};
            is($client->broker, $broker_code, "Successfully created real account $client->loginid");

            if ($mf_acc) {
                my ($mf_client) = @{$mf_acc}{qw/client/};
                is($mf_client->broker, 'MF', "Successfully created real account $mf_client->loginid");
            }
        }
    };

    subtest 'sync wihtdrawal_locked status to new clients upon creation' => sub {
        my $real_acc = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            details     => \%t_details,
        });
        my ($real_client, $user) = @{$real_acc}{'client', 'user'};
        $real_client->status->set('withdrawal_locked', 'system', 'transfer over 1k');
        $real_client->status->set('transfers_blocked', 'system', 'qiwi deposit');

        my $real_acc_new = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            details     => \%t_details,
        });
        my $real_client_new = @{$real_acc_new}{'client'};

        ok $real_client_new->status->withdrawal_locked, "withdrawal_locked status copied to new real client upon creation";
        ok $real_client_new->status->transfers_blocked, "transfers_blocked status is copied to new real client upon creation";

        my $client_vr_new = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });
        $user->add_client($client_vr_new);

        ok !$client_vr_new->status->withdrawal_locked, 'withdrawal_locked status must not set or copied for virtual accounts';
    };

    subtest 'sync poi/poa flags to new clients upon creation' => sub {
        my $real_acc = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            details     => \%t_details,
        });
        my ($real_client, $user) = @{$real_acc}{'client', 'user'};
        $real_client->status->set('allow_poi_resubmission', 'system', 'hello world');
        $real_client->status->set('allow_poa_resubmission', 'system', 'it is over 9000');

        my $real_acc_new = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            details     => \%t_details,
        });
        my $real_client_new = @{$real_acc_new}{'client'};

        ok $real_client_new->status->allow_poi_resubmission, "allow_poi_resubmission status copied to new real client upon creation";
        ok $real_client_new->status->allow_poa_resubmission, "allow_poa_resubmission status is copied to new real client upon creation";

        is $real_client_new->status->reason('allow_poi_resubmission'), 'hello world',
            "allow_poi_resubmission reason should not have the copied from part";
        is $real_client_new->status->reason('allow_poa_resubmission'), 'it is over 9000',
            "allow_poa_resubmission reason should not have the copied from part";

        my $client_vr_new = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });
        $user->add_client($client_vr_new);

        ok !$client_vr_new->status->allow_poi_resubmission, 'allow_poi_resubmission status must not set or copied for virtual accounts';
        ok !$client_vr_new->status->allow_poa_resubmission, 'allow_poa_resubmission status must not set or copied for virtual accounts';
    };

    subtest 'P2P account opening reason' => sub {

        my $vr_acc = create_vr_acc({
            email           => 'p2p_mlt@binary.com',
            client_password => 'test',
            residence       => 'nl',
        });
        my ($vr_client, $user) = @{$vr_acc}{'client', 'user'};

        my %details = (
            %real_client_details,
            first_name               => 'john',
            residence                => 'nl',
            citizen                  => 'nl',
            non_pep_declaration_time => Date::Utility->today->date_yyyymmdd,
            account_opening_reason   => 'Peer-to-peer exchange',
        );

        $details = BOM::Platform::Account::Real::default::validate_account_details(\%details, $vr_client, 'MLT', 1);
        is $details->{error}, 'P2PRestrictedCountry', 'error for P2P on MLT';

        $details = BOM::Platform::Account::Real::default::validate_account_details(\%details, $vr_client, 'CR', 1);
        ok !$details->{error}, 'no error for P2P on CR';

        $details{account_opening_reason} = 'Hedging';
        $details = BOM::Platform::Account::Real::default::validate_account_details(\%details, $vr_client, 'MLT', 1);
        ok !$details->{error}, 'no error for other reason on MLT';

        delete $details{account_opening_reason};
        $details = BOM::Platform::Account::Real::default::validate_account_details(\%details, $vr_client, 'MLT', 1);
        ok !$details->{error}, 'no warning if account_opening_reason is missing';
    };
};

sub create_vr_acc {
    my $args = shift;
    return BOM::Platform::Account::Virtual::create_account({
            details => {
                email              => $args->{email},
                client_password    => $args->{client_password},
                residence          => $args->{residence},
                has_social_signup  => $args->{social_signup},
                myaffiliates_token => $args->{myaffiliates_token},
                email_consent      => $args->{email_consent},
            }});
}

sub create_real_acc {
    my ($vr_client, $user, $broker) = @_;

    my %details = %real_client_details;
    $details{$_} = $vr_details->{$broker}->{$_} for qw(email residence address_state);
    $details{$_} = $broker                      for qw(broker_code first_name);
    $details{client_password} = $vr_client->password;

    return BOM::Platform::Account::Real::default::create_account({
        from_client => $vr_client,
        user        => $user,
        details     => \%details,
        country     => $vr_client->residence,
    });
}

sub create_mf_acc {
    my ($from_client, $user) = @_;

    my %details = %real_client_details;
    $details{$_}              = $from_client->$_ for qw(email residence);
    $details{broker_code}     = 'MF';
    $details{first_name}      = 'MF_' . $from_client->broker;
    $details{client_password} = $from_client->password;
    $details{phone}           = sprintf("+15417321%03d", rand(999));

    my $params = \%financial_data;
    $params->{accept_risk} = 1;
    return BOM::Platform::Account::Real::maltainvest::create_account({
        from_client => $from_client,
        user        => $user,
        details     => \%details,
        country     => $from_client->residence,
        params      => $params
    });
}

$idauth_mocked->unmock_all;
