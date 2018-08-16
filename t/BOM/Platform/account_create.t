use strict;
use warnings;
use Test::MockTime::HiRes;
use Guard;
use JSON::MaybeXS;

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
use BOM::Platform::Account::Real::japan;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Config;

my $on_production = 1;
my $config_mocked = Test::MockModule->new('BOM::Config');
$config_mocked->mock('on_production', sub { return $on_production });

my $vr_acc;
lives_ok {
    $vr_acc = create_vr_acc({
        email           => 'foo+us@binary.com',
        client_password => 'foobar',
        residence       => 'us',                  # US
    });
}
'create VR acc';
is($vr_acc->{error}, 'invalid residence', 'create VR acc failed: restricted country');

$on_production = 0;

my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $vr_details = {
    CR => {
        email              => 'foo+id@binary.com',
        client_password    => 'foobar',
        residence          => 'id',                  # Indonesia
        salutation         => 'Ms',
        myaffiliates_token => 'this is token',
    },
    MLT => {
        email              => 'foo+nl@binary.com',
        client_password    => 'foobar',
        residence          => 'nl',                  # Netherlands
        salutation         => 'Mr',
        myaffiliates_token => 'this is token',
    },
    MX => {
        email              => 'foo+gb@binary.com',
        client_password    => 'foobar',
        residence          => 'gb',                  # UK
        salutation         => 'Mrs',
        myaffiliates_token => 'this is token',
    },
    JP => {
        email              => 'foo+jp@binary.com',
        client_password    => 'foobar',
        residence          => 'jp',                  # JAPAN
        salutation         => 'Ms',
        myaffiliates_token => 'this is token',
    },
};

my %real_client_details = (
    salutation                    => 'Ms',
    last_name                     => 'binary',
    date_of_birth                 => '1990-01-01',
    address_line_1                => 'address 1',
    address_line_2                => 'address 2',
    address_city                  => 'city',
    address_state                 => 'state',
    address_postcode              => '89902872',
    phone                         => '82083808372',
    secret_question               => 'Mother\'s maiden name',
    secret_answer                 => 'sjgjdhgdjgdj',
    myaffiliates_token_registered => 0,
    checked_affiliate_exposures   => 0,
    latest_environment            => '',
    account_opening_reason        => 'Hedging',
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

my %jp_acc_financial_data = (
    annual_income                               => '50-100 million JPY',
    financial_asset                             => 'Over 100 million JPY',
    daily_loss_limit                            => 100_000,
    trading_experience_public_bond              => 'Over 5 years',
    trading_experience_margin_fx                => 'Over 5 years',
    trading_experience_equities                 => 'Over 5 years',
    trading_experience_commodities              => 'Over 5 years',
    trading_experience_foreign_currency_deposit => '3-5 years',
    trading_experience_investment_trust         => '3-5 years',
    trading_experience_option_trading           => 'Over 5 years',
    trading_purpose                             => 'Hedging',
    hedge_asset                                 => 'Foreign currency deposit',
    hedge_asset_amount                          => 1_000_000,
    motivation_circumstances                    => 'Web Advertisement',
);

my %jp_agreement = (
    agree_use_electronic_doc             => 1,
    agree_warnings_and_policies          => 1,
    confirm_understand_own_judgment      => 1,
    confirm_understand_trading_mechanism => 1,
    confirm_understand_total_loss        => 1,
    confirm_understand_judgment_time     => 1,
    confirm_understand_sellback_loss     => 1,
    confirm_understand_shortsell_loss    => 1,
    confirm_understand_company_profit    => 1,
    confirm_understand_expert_knowledge  => 1,
    declare_not_fatca                    => 1,
);

subtest 'create account' => sub {
    foreach my $broker (keys %$vr_details) {
        my ($real_acc, $vr_client, $real_client, $user);
        lives_ok {
            my $vr_acc = create_vr_acc($vr_details->{$broker});
            ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
            is($vr_client->myaffiliates_token, 'this is token', 'myaffiliates token ok');
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

        # MF acc
        if ($broker eq 'MLT' or $broker eq 'MX') {
            lives_ok { $real_acc = create_mf_acc($real_client, $user); } "create MF acc";
            is($real_acc->{client}->broker, 'MF', "Successfully create " . $real_acc->{client}->loginid);
            my $cl = BOM::User::Client->new({loginid => $real_acc->{client}->loginid});
            my $data = decode_fa($cl->financial_assessment());
            is $data->{forex_trading_experience}, '0-1 year', "got the forex trading experience";
        } else {
            warning_like { $real_acc = create_mf_acc($real_client, $user); } qr/maltainvest acc opening err/, "failed to create MF acc";
            is($real_acc->{error}, 'invalid', "$broker client can't open MF acc");
        }
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
            my ($client, $user) = @{$real_acc}{qw/client user/};
            is(defined $user,   1,            "Social login user with residence $user->residence has been created");
            is($client->broker, $broker_code, "Successfully created real account $client->loginid");
        } elsif ($broker_code eq 'JP') {
            #Social login user isn't able to create JP account
            $real_acc = BOM::Platform::Account::Real::japan::create_account({
                from_client    => $vr_client,
                user           => $social_login_user,
                details        => \%details,
                country        => $vr_client->residence,
                financial_data => \%jp_acc_financial_data,
                agreement      => \%jp_agreement,
            });
            my ($client, $user) = @{$real_acc}{qw/client user/};
            is($real_acc->{error}, 'social login user is prohibited', 'Social login user cannot create JP account');
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

            my ($client, $user) = @{$real_acc}{qw/client user/};
            is(defined $user,   1,            "Social login user with residence $user->residence has been created");
            is($client->broker, $broker_code, "Successfully created real account $client->loginid");
        }
    }
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
            }});
}

sub create_real_acc {
    my ($vr_client, $user, $broker) = @_;

    my %details = %real_client_details;
    $details{$_} = $vr_details->{$broker}->{$_} for qw(email residence);
    $details{$_} = $broker for qw(broker_code first_name);
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
    $details{$_} = $from_client->$_ for qw(email residence);
    $details{broker_code}     = 'MF';
    $details{first_name}      = 'MF_' . $from_client->broker;
    $details{client_password} = $from_client->password;

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

