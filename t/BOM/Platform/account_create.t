use strict;
use warnings;
use Test::MockTime::HiRes;
use Guard;

use Test::More (tests => 4);
use Test::Exception;
use Test::MockModule;
use BOM::Platform::Client::Utility;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Runtime;
use BOM::Platform::Account;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMD qw(:init);

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
is($vr_acc->{error}, 'invalid residence', 'create VR acc failed: restricted country');

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

subtest 'create account' => sub {
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
    $user->email_verified(1);
    $user->save;

    my %t_details = (
        %real_client_details,
        residence       => $t_vr_details{residence},
        broker_code     => $broker,
        first_name      => 'foonobug',
        client_password => $vr_client->password,
        email           => $t_vr_details{email});

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

};

subtest 'get_real_acc_opening_type' => sub {
    my $type_map = {
        'real'        => ['id', 'gb', 'nl'],
        'maltainvest' => ['de'],
        'japan'       => ['jp'],
        'restricted' => ['us', 'my'],
    };

    foreach my $acc_type (keys %$type_map) {
        foreach my $c (@{$type_map->{$acc_type}}) {
            my $vr_client;
            lives_ok {
                my $acc = create_vr_acc({
                    email           => 'shuwnyuan-test-' . $c . '@binary.com',
                    client_password => 'foobar',
                    residence       => ($acc_type eq 'restricted') ? 'id' : $c,
                });
                $vr_client = $acc->{client};
                $vr_client->residence($c);
            }
            'create vr acc';

            my $type_result;
            $type_result = $acc_type if ($acc_type ne 'restricted');
            is(BOM::Platform::Account::get_real_acc_opening_type({from_client => $vr_client}), $type_result,
                "$c: acc type - " . ($type_result // ''));
        }
    }
};

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

