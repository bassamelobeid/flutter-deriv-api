use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use Test::MockModule;
use BOM::Platform::Client::Utility;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

BOM::Platform::Runtime->instance->app_config->system->on_production(1);

my $vr_acc;
lives_ok {
    $vr_acc = create_vr_acc({
        email           => 'foo+us@binary.com',
        client_password => 'foobar',
        residence       => 'us',                  # US
    });
}
'create VR acc';
is($vr_acc->{error}, 'invalid', 'create VR acc failed: restricted country');

BOM::Platform::Runtime->instance->app_config->system->on_production(0);

my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $vr_details = {
    CR => {
        email           => 'foo+id@binary.com',
        client_password => 'foobar',
        residence       => 'id',                  # Indonesia
    },
    MLT => {
        email           => 'foo+nl@binary.com',
        client_password => 'foobar',
        residence       => 'nl',                  # Netherlands
    },
    MX => {
        email           => 'foo+gb@binary.com',
        client_password => 'foobar',
        residence       => 'gb',                  # UK
    },
};

my %real_client_details = (
    salutation       => 'Ms',
    last_name        => 'binary',
    date_of_birth    => '1990-01-01',
    address_line_1   => 'address 1',
    address_line_2   => 'address 2',
    address_city     => 'city',
    address_state    => 'state',
    address_postcode => '89902872',
    phone            => '82083808372',
    secret_question  => 'Mother\'s maiden name',
    secret_answer    => 'sjgjdhgdjgdj',
    ,
    myaffiliates_token_registered => 0,
    checked_affiliate_exposures   => 0,
    latest_environment            => '',
);

my %financial_data = (
    forex_trading_experience             => '0-1 year',
    forex_trading_frequency              => '0-5 transactions in the past 12 months',
    indices_trading_experience           => '0-1 year',
    indices_trading_frequency            => '0-5 transactions in the past 12 months',
    commodities_trading_experience       => '0-1 year',
    commodities_trading_frequency        => '0-5 transactions in the past 12 months',
    stocks_trading_experience            => '0-1 year',
    stocks_trading_frequency             => '0-5 transactions in the past 12 months',
    other_derivatives_trading_experience => '0-1 year',
    other_derivatives_trading_frequency  => '0-5 transactions in the past 12 months',
    other_instruments_trading_experience => '0-1 year',
    other_instruments_trading_frequency  => '0-5 transactions in the past 12 months',
    employment_industry                  => 'Finance',
    education_level                      => 'Secondary',
    income_source                        => 'Self-Employed',
    net_income                           => 'Less than $25,000',
    estimated_worth                      => 'Less than $100,000',
);

foreach my $broker (keys %$vr_details) {
    my ($real_acc, $vr_client, $real_client, $user);
    lives_ok {
        my $vr_acc = create_vr_acc($vr_details->{$broker});
        ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
    }
    'create VR acc';

    # real acc failed
    lives_ok { $real_acc = create_real_acc($vr_client, $user, $broker); } "create $broker acc";
    is($real_acc->{error}, 'email unverified', "create $broker acc failed: email verification required");

    $user->email_verified(1);
    $user->save;

    # real acc
    lives_ok {
        $real_acc = create_real_acc($vr_client, $user, $broker);
        ($real_client, $user) = @{$real_acc}{'client', 'user'};
    }
    "create $broker acc OK, after verify email";
    is($real_client->broker, $broker, 'Successfully create ' . $real_client->loginid);

    # duplicate acc
    lives_ok { $real_acc = create_real_acc($vr_client, $user, $broker); } "Try create duplicate $broker acc";
    is($real_acc->{error}, 'duplicate email', "Create duplicate $broker acc failed");

    # MF acc
    lives_ok { $real_acc = create_mf_acc($real_client, $user); } "create MF acc";
    if ($broker eq 'MLT') {
        is($real_acc->{client}->broker, 'MF', "Successfully create " . $real_acc->{client}->loginid);
    } else {
        is($real_acc->{error}, 'invalid', "$broker client can't open MF acc");
    }
}

sub create_vr_acc {
    my $args = shift;
    return BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
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

    return BOM::Platform::Account::Real::maltainvest::create_account({
        from_client    => $from_client,
        user           => $user,
        details        => \%details,
        country        => $from_client->residence,
        financial_data => \%financial_data,
        accept_risk    => 1,
    });
}

