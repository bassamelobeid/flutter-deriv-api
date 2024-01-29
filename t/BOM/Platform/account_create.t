use strict;
use warnings;
use Test::MockTime::HiRes;
use Guard;
use JSON::MaybeXS;
use Date::Utility;
use Array::Utils;

use Test::More (tests => 10);
use Test::Exception;
use Test::Fatal;
use Test::Warn;
use Test::MockModule;
use Test::Warnings;
use Test::Deep;

use BOM::User;
use BOM::User::Client;
use BOM::User::Client::Status;
use BOM::User::FinancialAssessment qw(decode_fa);
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Config;
use BOM::Test::Helper::FinancialAssessment;
use JSON::MaybeUTF8 qw(encode_json_utf8);

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
my %args = (
    email           => 'foo+us@binary.com',
    client_password => 'foobar',
    residence       => 'us',                  # US
    account_type    => ''
);
lives_ok {
    $vr_acc = create_vr_acc(\%args);
}
'create VR acc';
is $vr_acc->{error}->{code}, 'AccountTypeMissing', 'Missing account type';

is create_vr_acc({%args, account_type => 'dummy'})->{error}->{code}, 'InvalidAccountType', 'Invalid account type';
is create_vr_acc({%args, account_type => 'doughflow'})->{error}->{code}, 'InvalidDemoAccountType',
    'Doughflow account type (wallet) does not support demo account opening';

is(create_vr_acc({%args, account_type => 'standard'})->{error}->{code}, 'invalid residence', 'create VR acc failed: restricted country');

$on_production = 0;

my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $vr_details = {
    CR => [{
            account_type       => 'binary',
            email              => 'foo+id@binary.com',
            client_password    => 'foobar',
            residence          => 'id',                  # Indonesia
            address_state      => 'BA',
            salutation         => 'Ms',
            myaffiliates_token => 'this is token',
            email_consent      => 0,
            lc_email_consent   => 1,
        }
    ],
    MF => [{
            account_type       => 'binary',
            email              => 'foo+gb@binary.com',
            client_password    => 'foobar',
            residence          => 'gb',                  # UK
            address_state      => 'BIR',
            salutation         => 'Mrs',
            myaffiliates_token => 'this is token',
            email_consent      => 1,
            lc_email_consent   => 1,
            stopped            => 1,                     # this special flag indicates the account wont be created
        },
        {
            account_type       => 'binary',
            email              => 'foo+pt@binary.com',
            client_password    => 'foobar',
            residence          => 'pt',
            address_state      => 'BIR',
            salutation         => 'Mrs',
            myaffiliates_token => 'this is token',
            email_consent      => 1,
            lc_email_consent   => 1,
        },
    ],
};

my %real_client_details = (
    account_type                  => 'binary',
    salutation                    => 'Ms',
    last_name                     => 'binary',
    date_of_birth                 => '1990-01-01',
    address_line_1                => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01 1',
    address_line_2                => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01 2',
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
        subtest $broker => sub {
            foreach my $acc_details ($vr_details->{$broker}->@*) {
                subtest $acc_details->{residence} => sub {
                    my ($real_acc, $vr_client, $real_client, $user);
                    lives_ok {
                        my $vr_acc = create_vr_acc($acc_details);
                        ($vr_client, $user) = @{$vr_acc}{'client', 'user'};

                        if ($acc_details->{stopped}) {
                            ok !$vr_client, 'No virtual account created';
                            ok !$user,      'No user created';
                        } else {
                            is($vr_client->myaffiliates_token, 'this is token',               'myaffiliates token ok');
                            is($user->email_consent,           $acc_details->{email_consent}, 'email consent ok');
                        }
                    }
                    'create VR acc';

                    # if the VR acc got stopped I'd still like to test the real acc creation
                    # by creating a `platonic` VR client object

                    if ($acc_details->{stopped}) {
                        $user = BOM::User->create(
                            email          => $acc_details->{email},
                            password       => "pwd",
                            email_verified => 1,
                            email_consent  => $acc_details->{email_consent},
                        );

                        $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                            broker_code    => 'VRTC',
                            email          => $acc_details->{email},
                            binary_user_id => $user->id,
                            residence      => $acc_details->{residence},
                        });
                    }

                    # real acc
                    lives_ok {
                        if ($broker eq 'MF') {
                            $real_acc = create_mf_acc($vr_client, $user, $broker);
                        } else {
                            $real_acc = create_real_acc($vr_client, $user, $broker);
                        }

                        ($real_client, $user) = @{$real_acc}{'client', 'user'};
                    }
                    "create $broker acc OK, after verify email";
                    is($real_client->broker, $broker, 'Successfully create ' . $real_client->loginid);
                    # test account_opening_reason
                    is(
                        $real_client->account_opening_reason,
                        $real_client_details{account_opening_reason},
                        "Account Opening Reason should be the same"
                    );
                    is($real_client->user->email_consent, $acc_details->{email_consent}, 'email consent ok');

                    # MF acc
                    if ($broker eq 'MF') {
                        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
                        my $real_mock   = Test::MockModule->new('BOM::Platform::Account::Real::default');
                        # tricky stuff, is seems we only deploy one testing DB, so the trigger propagates the
                        # age verified regardless of broker code, making the test useless unless we do the following:
                        my $mf_fresh;
                        $real_mock->mock(
                            'copy_status_from_siblings',
                            sub {
                                my ($cur_client) = @_;
                                $mf_fresh = $cur_client;
                                return $real_mock->original('copy_status_from_siblings')->(@_);
                            });
                        $status_mock->mock(
                            'age_verification',
                            sub {
                                my ($self) = @_;
                                return 0 if $self->client_loginid eq $mf_fresh->loginid;
                                return {
                                    reason => 'test',
                                };
                            });

                        lives_ok { $real_acc = create_mf_acc($real_client, $user); } "create MF acc";
                        is($real_acc->{client}->broker, 'MF', "Successfully create " . $real_acc->{client}->loginid);
                        $status_mock->unmock_all;

                        my $cl   = BOM::User::Client->new({loginid => $real_acc->{client}->loginid});
                        my $data = decode_fa($cl->financial_assessment());
                        is $data->{forex_trading_experience}, '0-1 year', "got the forex trading experience";
                    }

                    # Prepare for the email_consent-less test
                    $acc_details->{email} = 'test_' . $acc_details->{email};
                    delete $acc_details->{email_consent};
                };
            }
        };
    }

    subtest 'LC email consent' => sub {
        foreach my $broker (keys %$vr_details) {
            subtest $broker => sub {
                foreach my $acc_details ($vr_details->{$broker}->@*) {
                    subtest $acc_details->{residence} => sub {
                        my ($real_acc, $vr_client, $real_client, $user);
                        lives_ok {
                            my $vr_acc = create_vr_acc($acc_details);
                            ($vr_client, $user) = @{$vr_acc}{'client', 'user'};

                            if ($acc_details->{stopped}) {
                                ok !$vr_client, 'No virtual account created';
                                ok !$user,      'No user created';
                            } else {
                                is($vr_client->myaffiliates_token, 'this is token',                  'myaffiliates token ok');
                                is($user->email_consent,           $acc_details->{lc_email_consent}, 'default email consent from LC is ok');
                            }
                        }
                        'create VR acc';

                        if ($acc_details->{stopped}) {
                            $user = BOM::User->create(
                                email          => $acc_details->{email},
                                password       => "pwd",
                                email_verified => 1,
                                email_consent  => $acc_details->{lc_email_consent},
                            );

                            $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                                broker_code    => 'VRTC',
                                email          => $acc_details->{email},
                                binary_user_id => $user->id,
                                residence      => $acc_details->{residence},
                            });
                        }

                        # real acc
                        lives_ok {
                            $real_acc = create_real_acc($vr_client, $user, $broker);
                            ($real_client, $user) = @{$real_acc}{'client', 'user'};
                        }
                        "create $broker acc OK, after verify email";
                        is($real_client->broker,              $broker,                          'Successfully create ' . $real_client->loginid);
                        is($real_client->user->email_consent, $acc_details->{lc_email_consent}, 'default email consent from LC is ok');
                    };
                }
            };
        }
    };

    # test create account in 2016-02-29
    set_absolute_time(1456724000);
    my $guard = guard { restore_time };

    my $broker       = 'CR';
    my %t_vr_details = (
        %{$vr_details->{CR}->[0]},
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
                    email        => 'foo+noresidence@binary.com',
                    account_type => 'virtual'
                }});
        ($vr_wallet_client, $user_wallet) = @{$vr_wallet_acc}{'client', 'user'};

    }
    'create VR wallet account';
    is($vr_wallet_client->account_type, 'virtual', 'correct account_type for virtual wallet');

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
                    email        => 'foo+noresidence@binary.com',
                    account_type => 'virtual'
                }});
        my ($vr_client_n, $user_n) = @{$vr_acc}{'client', 'user'};
    }
    'create VR acc without residence and password';

    subtest virtual_company_for_brand => sub {
        my %expected = (
            binary => 'virtual',
            deriv  => 'virtual',
        );

        for my $brand_name (sort keys %expected) {
            is(BOM::Platform::Account::Virtual::_virtual_company_for_brand($brand_name)->short,
                $expected{$brand_name}, "Got correct virtual company for $brand_name brand");
        }

        my %expected_wallet_company = (
            binary => 'virtual',
            deriv  => 'virtual',
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

    subtest 'email verified parameter' => sub {
        my $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email        => 'not_email_verified1@binary.com',
                    account_type => 'binary'
                }});
        ok $vr_acc_n->{user}->email_verified, 'User is email verified when email_verified detail is not provided as default is 1';

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email          => 'also_not_email_verified2@binary.com',
                    email_verified => 0,
                    account_type   => 'binary'
                }});
        ok !$vr_acc_n->{user}->email_verified, 'User is not email verified when email_verified=0 detail is provided';

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email          => 'email_verifie3d@binary.com',
                    email_verified => 1,
                    account_type   => 'binary'
                }});
        ok $vr_acc_n->{user}->email_verified, 'User is email verified when email_verified=1 detail is provided';
    };

    subtest date_first_contact => sub {
        my $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo1+datecontact@binary.com',
                    date_first_contact => Date::Utility->today->plus_time_interval('1d')->date_yyyymmdd,
                    account_type       => 'binary'
                }});
        is($vr_acc_n->{user}->date_first_contact, '2016-02-29', 'Date in future set to today');

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo5+datecontact@binary.com',
                    date_first_contact => '2016-13-40',
                    account_type       => 'binary'
                }});
        is($vr_acc_n->{user}->date_first_contact, '2016-02-29', 'Invalid date gets set to today');

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo2+datecontact@binary.com',
                    date_first_contact => Date::Utility->today->date_yyyymmdd,
                    account_type       => 'binary'
                }});
        isa_ok($vr_acc_n->{client}, 'BOM::User::Client', 'No error when today');

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo3+datecontact@binary.com',
                    date_first_contact => Date::Utility->today->minus_time_interval('40d')->date_yyyymmdd,
                    account_type       => 'binary'
                }});
        is($vr_acc_n->{user}->date_first_contact, '2016-01-30', 'When over 30 days old date_first_contact is 30 days old');

        $vr_acc_n = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email              => 'foo4+datecontact@binary.com',
                    date_first_contact => Date::Utility->today->minus_time_interval('20d')->date_yyyymmdd,
                    account_type       => 'binary'
                }});
        isa_ok($vr_acc_n->{client}, 'BOM::User::Client', 'No error when under 30 days old ');
    };

    $t_details{phone} = sprintf("+15417555%03d", rand(999));

    # real acc
    lives_ok {
        $real_acc = BOM::Platform::Account::Real::default::create_account({
            from_client  => $vr_client,
            user         => $user,
            details      => \%t_details,
            country      => $vr_client->residence,
            account_type => 'binary',
        });
        ($real_client, $user) = @{$real_acc}{'client', 'user'};
    }
    "create $broker acc OK, after verify email";
    is($real_client->broker, $broker, 'Successfully create ' . $real_client->loginid);

    subtest 'gender from salutation' => sub {
        my $expected = ($vr_details->{$broker}->[0]->{salutation} eq 'Mr') ? 'm' : 'f';
        is($real_client->gender, $expected, $vr_details->{$broker}->[0]->{salutation} . " is $expected");
    };

    # mock virtual account with social signup flag
    subtest 'Social signup flag' => sub {
        foreach my $broker_code (keys %$vr_details) {
            subtest $broker_code => sub {
                foreach my $acc_details ($vr_details->{$broker_code}->@*) {
                    my $residence = $acc_details->{residence};

                    subtest $residence => sub {
                        my %social_login_user_details = (
                            $acc_details->%*,
                            email         => 'social+' . $broker_code . '+' . $residence . '@binary.com',
                            social_signup => 1
                        );
                        my ($vr_client, $real_client, $social_login_user, $real_acc);
                        lives_ok {
                            my $vr_acc = create_vr_acc(\%social_login_user_details);
                            ($vr_client, $social_login_user) = @{$vr_acc}{qw/client user/};
                            if ($acc_details->{stopped}) {
                                ok !$vr_client,         'No virtual account created';
                                ok !$social_login_user, 'No user created';
                            }
                        }
                        'create VR account';

                        if ($acc_details->{stopped}) {
                            $social_login_user = BOM::User->create(
                                email             => $acc_details->{email},
                                password          => "pwd",
                                has_social_signup => 1,
                                %social_login_user_details,
                            );

                            $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                                broker_code    => 'VRTC',
                                email          => $acc_details->{email},
                                binary_user_id => $user->id,
                                residence      => $acc_details->{residence},
                            });
                        }

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
                                    from_client  => $vr_client,
                                    user         => $social_login_user,
                                    details      => \%details,
                                    country      => $vr_client->residence,
                                    params       => $params,
                                    account_type => 'binary',
                                });
                            }
                            "create $broker_code account OK, after verify email";
                        } else {
                            # Social login user may create default account
                            lives_ok {
                                $real_acc = BOM::Platform::Account::Real::default::create_account({
                                    from_client  => $vr_client,
                                    user         => $social_login_user,
                                    details      => \%details,
                                    country      => $vr_client->residence,
                                    account_type => 'binary'
                                });
                            }
                            "create $broker_code account OK, after verify email";
                        }

                        my ($client, $user) = @{$real_acc}{qw/client user/};
                        is(defined $user,   1,            "Social login user with residence $user->residence has been created");
                        is($client->broker, $broker_code, "Successfully created real account $client->loginid");
                    };
                }
            };
        }
    };

    subtest 'Empty phone number' => sub {
        foreach my $broker_code (keys %$vr_details) {
            subtest $broker_code => sub {
                foreach my $acc_details ($vr_details->{$broker_code}->@*) {
                    my $residence = $acc_details->{residence};

                    subtest $residence => sub {
                        my %empty_phone_number_details = (
                            $acc_details->%*,
                            email         => 'empty_phone+' . $broker_code . '+' . $residence . '@binary.com',
                            phone         => '',
                            social_signup => 1,
                            account_type  => 'binary',
                        );
                        my ($vr_client, $real_client, $empty_phone_login_user, $real_acc);
                        lives_ok {
                            my $vr_acc = create_vr_acc(\%empty_phone_number_details);
                            ($vr_client, $empty_phone_login_user) = @{$vr_acc}{qw/client user/};
                            if ($acc_details->{stopped}) {
                                ok !$vr_client,              'No virtual account created';
                                ok !$empty_phone_login_user, 'No user created';
                            }
                        }
                        'create VR account';

                        if ($acc_details->{stopped}) {
                            $empty_phone_login_user = BOM::User->create(
                                email          => $acc_details->{email},
                                password       => "pwd",
                                email_verified => 1,
                                %empty_phone_number_details,
                            );

                            $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                                broker_code    => 'VRTC',
                                email          => $acc_details->{email},
                                binary_user_id => $user->id,
                                residence      => $acc_details->{residence},
                                account_type   => 'binary'
                            });
                        }

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
                        if ($broker_code eq 'MF') {
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
                    };
                }
            };
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
            broker_code  => 'VRTC',
            account_type => 'binary'
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
        $real_client->status->set('allow_poi_resubmission',  'system', 'hello world');
        $real_client->status->set('allow_poa_resubmission',  'system', 'it is over 9000');
        $real_client->status->set('poi_name_mismatch',       'system', 'bad name');
        $real_client->status->set('poi_dob_mismatch',        'system', 'bad dob');
        $real_client->status->set('financial_risk_approval', 'system', 'Client accepted financial risk disclosure');

        my $real_acc_new = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            details     => \%t_details,
        });
        my $real_client_new = @{$real_acc_new}{'client'};

        ok $real_client_new->status->allow_poi_resubmission, "allow_poi_resubmission status copied to new real client upon creation";
        ok $real_client_new->status->allow_poa_resubmission, "allow_poa_resubmission status is copied to new real client upon creation";
        ok $real_client_new->status->poi_name_mismatch,      "poi_name_mismatch status is copied to new real client upon creation";
        ok $real_client_new->status->poi_dob_mismatch,       "poi_dob_mismatch status is copied to new real client upon creation";

        is $real_client_new->status->reason('allow_poi_resubmission'), 'hello world',
            "allow_poi_resubmission reason should not have the copied from part";
        is $real_client_new->status->reason('allow_poa_resubmission'), 'it is over 9000',
            "allow_poa_resubmission reason should not have the copied from part";
        is $real_client_new->status->reason('poi_name_mismatch'), 'bad name', "poi_name_mismatch reason should not have the copied from part";
        is $real_client_new->status->reason('poi_dob_mismatch'),  'bad dob',  "poi_dob_mismatch reason should not have the copied from part";
        ok !$real_client_new->status->financial_risk_approval, "financial_risk_approval not copied";

        my $client_vr_new = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });
        $user->add_client($client_vr_new);

        ok !$client_vr_new->status->allow_poi_resubmission, 'allow_poi_resubmission status must not set or copied for virtual accounts';
        ok !$client_vr_new->status->allow_poa_resubmission, 'allow_poa_resubmission status must not set or copied for virtual accounts';
    };

    subtest 'sync status from duplicated siblings' => sub {
        my ($vr_client, $user);

        lives_ok {
            my $vr_acc = create_vr_acc({
                email     => 'supertest+du@binary.com',
                password  => 'okcomputer',
                residence => 'br',
            });
            ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
        }
        'create VR acc';

        my $real_acc = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            details     => \%t_details,
        });

        my ($real_client) = @{$real_acc}{'client'};
        $real_client->status->set('allow_poi_resubmission',  'system', 'hello world');
        $real_client->status->set('allow_poa_resubmission',  'system', 'it is over 9000');
        $real_client->status->set('poi_name_mismatch',       'system', 'bad name');
        $real_client->status->set('poi_dob_mismatch',        'system', 'bad dob');
        $real_client->status->set('duplicate_account',       'system', 'Duplicate account - currency change');
        $real_client->status->set('financial_risk_approval', 'system', 'Client accepted financial risk disclosure');

        my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
        $real_client->financial_assessment({
            data => encode_json_utf8($data),
        });
        $real_client->save();

        my $real_acc_new = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            details     => \%t_details,
        });
        my $real_client_new = @{$real_acc_new}{'client'};

        ok $real_client_new->status->allow_poi_resubmission,  "allow_poi_resubmission status copied to new real client upon creation";
        ok $real_client_new->status->allow_poa_resubmission,  "allow_poa_resubmission status is copied to new real client upon creation";
        ok $real_client_new->status->poi_name_mismatch,       "poi_name_mismatch status is copied to new real client upon creation";
        ok $real_client_new->status->poi_dob_mismatch,        "poi_dob_mismatch status is copied to new real client upon creation";
        ok $real_client_new->status->financial_risk_approval, "financial_risk_approval status is copied to new real client upon creation";

        ok $real_client_new->is_financial_assessment_complete, 'Financial assessment completed';

        my $fa = $real_client_new->financial_assessment();
        $fa = decode_fa($fa);

        cmp_deeply $data, $fa, 'Copied the FA from dup client';

        is $real_client_new->status->reason('allow_poi_resubmission'), 'hello world',
            "allow_poi_resubmission reason should not have the copied from part";
        is $real_client_new->status->reason('allow_poa_resubmission'), 'it is over 9000',
            "allow_poa_resubmission reason should not have the copied from part";
        is $real_client_new->status->reason('poi_name_mismatch'), 'bad name', "poi_name_mismatch reason should not have the copied from part";
        is $real_client_new->status->reason('poi_dob_mismatch'),  'bad dob',  "poi_dob_mismatch reason should not have the copied from part";
        is $real_client_new->status->reason('financial_risk_approval'), 'Client accepted financial risk disclosure',
            "financial_risk_approval reason should not have the copied from part";

        my $client_vr_new = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code  => 'VRTC',
            account_type => 'binary'
        });
        $user->add_client($client_vr_new);

        ok !$client_vr_new->status->allow_poi_resubmission, 'allow_poi_resubmission status must not set or copied for virtual accounts';
        ok !$client_vr_new->status->allow_poa_resubmission, 'allow_poa_resubmission status must not set or copied for virtual accounts';
    };
};

subtest 'create affiliate' => sub {
    my ($vr_client, $aff, $user);
    lives_ok {
        my $vr_acc = create_vr_acc({
            email     => 'afftest@binary.com',
            password  => 'okcomputer',
            residence => 'br',
        });
        ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
    }
    'create VR acc';

    lives_ok {
        $aff = BOM::Platform::Account::Real::default::create_account({
                from_client => $vr_client,
                user        => $user,
                details     => {
                    broker_code              => 'CRA',
                    email                    => 'afftest@binary.com',
                    account_type             => 'affiliate',
                    client_password          => 'okcomputer',
                    residence                => 'br',
                    first_name               => 'test',
                    last_name                => 'asdf',
                    address_line_1           => 'super st',
                    address_city             => 'sao paulo',
                    phone                    => '+381902941243',
                    secret_question          => 'Mother\'s maiden name',
                    secret_answer            => 'the iron maiden',
                    account_opening_reason   => 'Hedging',
                    non_pep_declaration_time => Date::Utility->new()->_plus_years(1)->date_yyyymmdd,
                }});
    }
    'create CRA acc';

    isa_ok $aff->{client}, 'BOM::User::Affiliate', 'Expected package for CRA';
};

subtest 'Sibling Status Sync upon creation' => sub {

    my $vr_account = create_vr_acc({
        email     => 'someclient@binary.com',
        password  => 'Secret0',
        residence => 'br',
    });

    my $vr_client = @{$vr_account}{'client'};
    my $user      = @{$vr_account}{'user'};

    my $real_acc = create_real_acc($vr_client, $user, 'CR');

    my ($real_client) = @{$real_acc}{'client'};

    my @statuses_to_be_copied = (
        'no_trading',               'withdrawal_locked',      'age_verification',        'transfers_blocked',
        'allow_poi_resubmission',   'allow_poa_resubmission', 'potential_fraud',         'poi_name_mismatch',
        'poi_dob_mismatch',         'cashier_locked',         'unwelcome',               'no_withdrawal_or_trading',
        'internal_client',          'shared_payment_method',  'df_deposit_requires_poi', 'poi_name_mismatch',
        'smarty_streets_validated', 'address_verified',       'poi_dob_mismatch',        'cooling_off_period',
        'poi_poa_uploaded',         'poa_address_mismatch'
    );

    subtest 'Statuses that should be copied' => sub {

        for my $status (@statuses_to_be_copied) {
            $real_client->status->upsert($status, 'system', "$status is now set");
        }

        my $real_acc_new    = create_real_acc($vr_client, $user, 'CR');
        my $real_client_new = @{$real_acc_new}{'client'};

        for my $status (@statuses_to_be_copied) {
            ok $real_client_new->status->$status->{staff_name} eq $real_client->status->$status->{staff_name},
                "$status staff_name copied to new real client upon creation";
            if ($status =~ /allow_po(i|a)_resubmission/ || $status =~ /poi_(.*)_mismatch/ || $status eq 'financial_risk_approval') {
                ok $real_client_new->status->reason($status) eq $real_client->status->reason($status),
                    "$status reason copied to new real client upon creation";
            } elsif ($status eq 'age_verification' or $status eq 'address_verified') {
                ok $real_client_new->status->reason($status) eq "Copied from " . $vr_client->loginid,
                    "$status reason copied to new real client upon creation";
            } else {
                ok $real_client_new->status->reason($status) eq $real_client->status->reason($status) . " - copied from " . $real_client->loginid,
                    "$status reason copied to new real client upon creation";
            }
        }
    };

    subtest 'Statuses that shouldn\'t be copied' => sub {

        my @all_statuses              = BOM::User::Client::Status::STATUS_CODES;
        my @statuses_not_to_be_copied = Array::Utils::array_diff(@all_statuses, @statuses_to_be_copied);

        for my $status (@statuses_not_to_be_copied) {
            $real_client->status->upsert($status, 'system', "$status is now set");
        }

        my $real_acc_new    = create_real_acc($vr_client, $user, 'CR');
        my $real_client_new = @{$real_acc_new}{'client'};

        for my $status (@statuses_not_to_be_copied) {
            if ($real_client_new->status->$status) {
                # if status is present then reason should not match
                ok $real_client_new->status->reason($status) ne $real_client->status->reason($status) . " - copied from " . $real_client->loginid,
                    "$status reason not copied to new real client upon creation";
            } else {
                ok !$real_client_new->status->$status, "$status status not copied to new real client upon creation";
            }
        }
    };

};

subtest 'email verification for virtual accounts' => sub {
    my $vr_details = {
        test => [{
                account_type     => 'binary',
                email            => 'foo+test1@binary.com',
                client_password  => 'foobar',
                residence        => 'id',                     # Indonesia
                address_state    => 'BA',
                salutation       => 'Ms',
                email_consent    => 1,
                lc_email_consent => 1,
                email_verified   => 0,
            },
            {
                account_type     => 'binary',
                email            => 'foo+test2@binary.com',
                client_password  => 'foobar',
                residence        => 'id',                     # Indonesia
                address_state    => 'BA',
                salutation       => 'Ms',
                email_consent    => 1,
                lc_email_consent => 1,
            }
        ],
    };

    my $vr_acc = create_vr_acc($vr_details->{test}->[0]);
    my ($vr_client, $user) = @{$vr_acc}{'client', 'user'};

    ok !$user->email_verified, 'email not verified as it should be overriden if email_verified field is passed to create acc function';

    $vr_acc = create_vr_acc($vr_details->{test}->[1]);
    ($vr_client, $user) = @{$vr_acc}{'client', 'user'};

    ok $user->email_verified, 'email verified as if email_verified field is not passed should default to value 1';

};

sub create_vr_acc {
    my $args = shift;
    return BOM::Platform::Account::Virtual::create_account({
            details => {
                email              => $args->{email},
                account_type       => $args->{account_type} // 'binary',
                client_password    => $args->{client_password},
                residence          => $args->{residence},
                has_social_signup  => $args->{social_signup},
                myaffiliates_token => $args->{myaffiliates_token},
                email_consent      => $args->{email_consent},
                email_verified     => $args->{email_verified},
            }});
}

sub create_real_acc {
    my ($vr_client, $user, $broker) = @_;

    my %details = %real_client_details;
    $details{$_}              = $vr_client->$_ for qw(email residence address_state);
    $details{$_}              = $broker        for qw(broker_code first_name);
    $details{client_password} = $vr_client->password;
    $details{account_type} //= 'binary';

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
        account_type => $details{account_type} // 'binary',
        from_client  => $from_client,
        user         => $user,
        details      => \%details,
        country      => $from_client->residence,
        params       => $params
    });
}

$idauth_mocked->unmock_all
