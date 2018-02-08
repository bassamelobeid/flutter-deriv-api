use strict;
use warnings;
use Test::More tests => 5;
use Test::Warnings;
use Test::Exception;

use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Account::Virtual;
use BOM::RPC::v3::NewAccount;
use BOM::RPC::v3::Japan::NewAccount;
use BOM::RPC::v3::Accounts;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

## do not send email
my $client_mocked = Test::MockModule->new('Client::Account');
$client_mocked->mock('add_note', sub { return 1 });

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

my ($vr_client, $user, $jp_loginid, $jp_client, $res);

subtest 'create VRTJ & JP client' => sub {
    # new VR client
    ($vr_client, $user) = create_vr_account({
        email           => 'test@binary.com',
        client_password => 'abc123',
        residence       => 'jp',
    });

    # new JP client
    $res = BOM::RPC::v3::NewAccount::new_account_japan({
        client => $vr_client,
        args   => \%jp_client_details
    });
    like $res->{client_id}, qr/^JP\d+$/, "JP client created";

    # activate JP real money a/c
    $jp_client = Client::Account->new({loginid => $res->{client_id}});
    $jp_client->clr_status('disabled');
    $jp_client->set_status('jp_activation_pending', 'test', 'for test');
    $jp_client->save;
};

my @jp_only = qw(
    gender
    occupation
    daily_loss_limit
    annual_income
    financial_asset
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
    $res = BOM::RPC::v3::Accounts::get_settings({client => $vr_client});
    is($res->{jp_settings}, undef, "no JP settings for Japan Virtual Acc");
};

subtest 'JP set_settings' => sub {
    my $params = {
        client       => $jp_client,
        website_name => 'Binary.com',
        client_ip    => '127.0.0.1',
        user_agent   => 'sdssasd',
        language     => 'ja',
        args         => {
            jp_settings            => {occupation => 'Financial Director'},
            address_line_1         => 'address line 1',
            address_line_2         => 'address line 2',
            address_city           => 'address city',
            address_state          => 'address state',
            address_postcode       => '12345',
            phone                  => '2345678',
            account_opening_reason => 'Hedging',
        }};
    $res = BOM::RPC::v3::Accounts::set_settings($params);
    ok $res->{status}, 'Settings updated accordingly';
};

subtest 'non-JP client get_settings' => sub {
    subtest 'create VRTC & CR client' => sub {
        ($vr_client, $user) = create_vr_account({
            email           => 'test+au@binary.com',
            client_password => 'abc123',
            residence       => 'au',
        });

        # new CR client
        my %cr_client_details = (
            salutation             => 'Ms',
            last_name              => 'last-name',
            first_name             => 'first-name',
            date_of_birth          => '1990-12-30',
            residence              => 'au',
            address_line_1         => 'Jalan Usahawan',
            address_line_2         => 'Enterpreneur Center',
            address_city           => 'Cyberjaya',
            address_state          => 'Selangor',
            address_postcode       => '47120',
            phone                  => '+603 34567890',
            secret_question        => 'Favourite dish',
            secret_answer          => 'nasi lemak,teh tarik',
            account_opening_reason => 'Hedging',
        );

        $res = BOM::RPC::v3::NewAccount::new_account_real({
            client => $vr_client,
            args   => \%cr_client_details
        });
        my $cr_loginid = $res->{client_id};
        like($cr_loginid, qr/^CR\d+$/, "got CR client $cr_loginid");
    };

    subtest 'VRTC - get_settings' => sub {
        $res = BOM::RPC::v3::Accounts::get_settings({client => $vr_client});
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
