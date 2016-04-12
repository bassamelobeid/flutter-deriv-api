use strict;
use warnings;
use Test::More tests => 4;
use Test::Exception;
use JSON;

use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Account::Virtual;
use BOM::RPC::v3::NewAccount;
use BOM::RPC::v3::NewAccount::Japan;
use BOM::RPC::v3::Accounts;

## do not send email
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my %jp_client_details = (
    gender                                      => 'f',
    first_name                                  => 'first-name',
    last_name                                   => 'last-name',
    date_of_birth                               => '1990-12-30',
    occupation                                  => 'Director',
    residence                                   => 'jp',
    address_line_1                              => 'Hiroo Miyata Bldg 3F',
    address_line_2                              => '9-16, Hiroo 1-chome',
    address_city                                => 'Shibuya-ku',
    address_state                               => 'Tokyo',
    address_postcode                            => '150-0012',
    phone                                       => '+81 3 4333 6908',
    secret_question                             => 'Favourite dish',
    secret_answer                               => 'nasi lemak,teh tarik',
    annual_income                               => '50-100 million JPY',
    financial_asset                             => 'Over 100 million JPY',
    daily_loss_limit                            => 100000,
    trading_experience_equities                 => 'Over 5 years',
    trading_experience_commodities              => 'Over 5 years',
    trading_experience_foreign_currency_deposit => '3-5 years',
    trading_experience_margin_fx                => '6 months to 1 year',
    trading_experience_investment_trust         => '3-5 years',
    trading_experience_public_bond              => 'Over 5 years',
    trading_experience_option_trading           => 'Less than 6 months',
    trading_purpose                             => 'Hedging',
    hedge_asset                                 => 'Foreign currency deposit',
    hedge_asset_amount                          => 1000000,
    agree_use_electronic_doc                    => 1,
    agree_warnings_and_policies                 => 1,
    confirm_understand_own_judgment             => 1,
    confirm_understand_trading_mechanism        => 1,
    confirm_understand_judgment_time            => 1,
    confirm_understand_total_loss               => 1,
    confirm_understand_sellback_loss            => 1,
    confirm_understand_shortsell_loss           => 1,
    confirm_understand_company_profit           => 1,
    confirm_understand_expert_knowledge         => 1,
    declare_not_fatca                           => 1,
);

my ($vr_client, $user, $token, $jp_loginid, $jp_client, $res);

subtest 'create VRTJ & JP client' => sub {
    # new VR client
    ($vr_client, $user) = create_vr_account({
        email           => 'test@binary.com',
        client_password => 'abc123',
        residence       => 'jp',
    });

    $token = BOM::Platform::SessionCookie->new(
        loginid => $vr_client->loginid,
        email   => $vr_client->email,
    )->token;

    # new JP client
    $res = BOM::RPC::v3::NewAccount::new_account_japan({
        token => $token,
        args  => \%jp_client_details
    });
    $jp_loginid = $res->{client_id};
    like $jp_loginid, qr/^JP\d+$/, "JP client created";

    # activate JP real money a/c
    $jp_client = BOM::Platform::Client->new({loginid => $jp_loginid});
    $jp_client->clr_status('disabled');
    $jp_client->set_status('jp_activation_pending', 'test', 'for test');
    $jp_client->save;
};

my @jp_only = qw(
    annual_income
    financial_asset
    daily_loss_limit
    trading_experience_equities
    trading_experience_commodities
    trading_experience_foreign_currency_deposit
    trading_experience_margin_fx
    trading_experience_investment_trust
    trading_experience_public_bond
    trading_experience_option_trading
    trading_purpose
    hedge_asset
    hedge_asset_amount
);

subtest 'VRTJ get_settings' => sub {
    $res = BOM::RPC::v3::Accounts::get_settings({token => $token});
    is $res->{jp_settings}, undef, "no JP settings for Japan Virtual Acc");
};

subtest 'JP get_settings' => sub {
    $token = BOM::Platform::SessionCookie->new(
        loginid => $jp_client->loginid,
        email   => $jp_client->email,
    )->token;

    $res = BOM::RPC::v3::Accounts::get_settings({token => $token});

    my %jp_only = (
        salutation    => '',
        country_code  => 'jp',
        date_of_birth => Date::Utility->new($jp_client_details{date_of_birth})->epoch
    );

    my @common = qw(
        gender
        first_name
        last_name
        occupation
        address_line_1
        address_line_2
        address_city
        address_state
        address_postcode
        phone
    );

    is($res->{$_}, $jp_client_details{$_}, "OK: $_" ) for (@common);
    is($res->{jp_settings}->{$_}, $jp_only{$_}, "OK: $_") for (keys %jp_only);
};

subtest 'non-JP client get_settings' => sub {
    subtest 'create VRTC & CR client' => sub {
        ($vr_client, $user) = create_vr_account({
            email           => 'test+au@binary.com',
            client_password => 'abc123',
            residence       => 'au',
        });

        $token = BOM::Platform::SessionCookie->new(
            loginid => $vr_client->loginid,
            email   => $vr_client->email,
        )->token;

        # new CR client
        my %cr_client_details = (
            salutation       => 'Ms',
            last_name        => 'last-name',
            first_name       => 'first-name',
            date_of_birth    => '1990-12-30',
            residence        => 'au',
            address_line_1   => 'Jalan Usahawan',
            address_line_2   => 'Enterpreneur Center',
            address_city     => 'Cyberjaya',
            address_state    => 'Selangor',
            address_postcode => '47120',
            phone            => '+603 34567890',
            secret_question  => 'Favourite dish',
            secret_answer    => 'nasi lemak,teh tarik',
        );

        $res = BOM::RPC::v3::NewAccount::new_account_real({
            token => $token,
            args  => \%cr_client_details
        });
        my $cr_loginid = $res->{client_id};
        like($cr_loginid, qr/^CR\d+$/, "got CR client $cr_loginid");
    };

    subtest 'VRTC - get_settings' => sub {
        $res = BOM::RPC::v3::Accounts::get_settings({token => $token});
        is($res->{jp_settings}, undef, "no jp_settings for VRTC");
    };
};

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
            },
            email_verified => 1
        });

    return ($acc->{client}, $acc->{user});
}

