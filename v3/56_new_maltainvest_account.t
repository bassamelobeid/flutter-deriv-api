use strict;
use warnings;
use Test::More tests => 5;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('Client::Account');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_wsapi_test();

my %client_details = (
    new_account_real          => 1,
    salutation                => 'Ms',
    last_name                 => 'last-name',
    first_name                => 'first\'name',
    date_of_birth             => '1990-12-30',
    residence                 => 'nl',
    place_of_birth            => 'de',
    address_line_1            => 'Jalan Usahawan',
    address_line_2            => 'Enterpreneur Center',
    address_city              => 'Cyberjaya',
    address_state             => 'Selangor',
    address_postcode          => '47120',
    phone                     => '+603 34567890',
    secret_question           => 'Favourite dish',
    secret_answer             => 'nasi lemak,teh tarik',
    tax_residence             => 'de,nl',
    tax_identification_number => '111-222-333',
    account_opening_reason    => 'Speculative',
);

my $mf_details = {
    new_account_maltainvest              => 1,
    account_turnover                     => 'Less than $25,000',
    forex_trading_experience             => '1-2 years',
    forex_trading_frequency              => '0-5 transactions in the past 12 months',
    indices_trading_experience           => '1-2 years',
    indices_trading_frequency            => '0-5 transactions in the past 12 months',
    commodities_trading_experience       => '1-2 years',
    commodities_trading_frequency        => '0-5 transactions in the past 12 months',
    stocks_trading_experience            => '1-2 years',
    stocks_trading_frequency             => '0-5 transactions in the past 12 months',
    other_derivatives_trading_experience => '1-2 years',
    other_derivatives_trading_frequency  => '0-5 transactions in the past 12 months',
    other_instruments_trading_frequency  => '0-5 transactions in the past 12 months',
    other_instruments_trading_experience => '1-2 years',
    employment_industry                  => 'Construction',
    education_level                      => 'Secondary',
    income_source                        => 'Investments & Dividends',
    net_income                           => '$25,000 - $50,000',
    estimated_worth                      => '$250,001 - $500,000',
    "occupation"                         => 'Managers',
    accept_risk                          => 1,
    account_opening_reason               => 'Speculative',
};

subtest 'MLT upgrade to MF account' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+nl@binary.com',
        client_password => 'abc123',
        residence       => 'nl',
    });

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    subtest 'create MLT account, authorize' => sub {
        $t = $t->send_ok({json => \%client_details})->message_ok;
        my $res = decode_json($t->message->[1]);
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);

        my $loginid = $res->{new_account_real}->{client_id};
        like($loginid, qr/^MLT\d+$/, "got MLT client $loginid");

        ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
        $t = $t->send_ok({json => {authorize => $token}})->message_ok;
    };

    subtest 'upgrade to MF' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        note explain %details;
        $t = $t->send_ok({json => \%details})->message_ok;
        my $res = decode_json($t->message->[1]);
        not explain $res;
        is($res->{msg_type}, 'new_account_maltainvest');
        ok($res->{new_account_maltainvest});
        test_schema('new_account_maltainvest', $res);

        my $loginid = $res->{new_account_maltainvest}->{client_id};
        like($loginid, qr/^MF\d+$/, "got MF client $loginid");

        my $client = Client::Account->new({loginid => $loginid});
        isnt($client->financial_assessment->data, undef, 'has financial assessment');
    };
};

subtest 'VR upgrade to MF - Germany' => sub {
    # create VR acc, authorize
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+de@binary.com',
        client_password => 'abc123',
        residence       => 'de',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    subtest 'upgrade to MF' => sub {
        my %details = (%client_details, %$mf_details);
        delete $details{new_account_real};
        $details{first_name} = 'first name DE';
        $details{residence}  = 'de';

        $t = $t->send_ok({json => \%details})->message_ok;
        my $res = decode_json($t->message->[1]);
        ok($res->{new_account_maltainvest});
        test_schema('new_account_maltainvest', $res);

        my $loginid = $res->{new_account_maltainvest}->{client_id};
        like($loginid, qr/^MF\d+$/, "got MF client $loginid");

        my $client = Client::Account->new({loginid => $loginid});
        isnt($client->financial_assessment->data, undef, 'has financial assessment');

        is($client->place_of_birth, 'de',    'correct place of birth');
        is($client->tax_residence,  'de,nl', 'correct tax residence');
    };
};

subtest 'CR / MX client cannot upgrade to MF' => sub {
    my %broker_map = (
        'CR' => {
            residence  => 'id',
            email      => 'test+id@binary.com',
            first_name => 'first name ID',
        },
        'MX' => {
            residence  => 'gb',
            email      => 'test+gb@binary.com',
            first_name => 'first name GB',
        },
    );

    foreach my $broker (keys %broker_map) {
        my $map = $broker_map{$broker};
        # create VR acc, authorize
        my ($vr_client, $user) = create_vr_account({
            email           => $map->{email},
            residence       => $map->{residence},
            client_password => 'abc123',
        });
        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t = $t->send_ok({json => {authorize => $token}})->message_ok;

        subtest 'create MX / CR acc, authorize' => sub {
            my %details = %client_details;
            $details{first_name} = $map->{first_name};
            $details{residence}  = $map->{residence};

            $t = $t->send_ok({json => \%details})->message_ok;
            my $res = decode_json($t->message->[1]);
            ok($res->{new_account_real});
            test_schema('new_account_real', $res);

            my $loginid = $res->{new_account_real}->{client_id};
            like($loginid, qr/^$broker\d+$/, "got $broker client $loginid");

            ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
            $t = $t->send_ok({json => {authorize => $token}})->message_ok;
        };

        subtest 'no MF upgrade for MX' => sub {
            my %details = (%client_details, %$mf_details);
            delete $details{new_account_real};
            $t = $t->send_ok({json => \%details})->message_ok;
            my $res = decode_json($t->message->[1]);

            is($res->{msg_type}, 'new_account_maltainvest');
            is($res->{error}->{code},           'InvalidAccount', "no MF upgrade for $broker");
            is($res->{new_account_maltainvest}, undef,            'NO account created');
        };
    }
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

$t->finish_ok;
