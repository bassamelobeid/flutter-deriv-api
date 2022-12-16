use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;

use BOM::MyAffiliates::BackfillManager;

subtest 'backfill_promo_codes' => sub {

    my ($all_broker_codes, @mock_clients, $expected, @got);
    my $mock_user_client = Test::MockModule->new("BOM::User::Client");
    $mock_user_client->redefine(by_promo_code => sub { return @mock_clients });
    my $mock_myaffiliates          = Test::MockModule->new("BOM::MyAffiliates");
    my $mock_myaffiliates_response = {};
    $mock_myaffiliates->redefine('get_token'                          => sub { return $mock_myaffiliates_response->{"token"} });
    $mock_myaffiliates->redefine('get_affiliate_id_from_token'        => sub { return $mock_myaffiliates_response->{"id_from_token"} });
    $mock_myaffiliates->redefine('get_myaffiliates_id_for_promo_code' => sub { return $mock_myaffiliates_response->{"id_from_promo_code"} });
    $mock_myaffiliates->redefine('is_subordinate_affiliate'           => sub { return $mock_myaffiliates_response->{"subordinate"} });
    $all_broker_codes = ["CR"];

    my $backfill_manager = BOM::MyAffiliates::BackfillManager->new(_available_broker_codes => $all_broker_codes);

    @mock_clients = ();
    $expected     = ['No clients processed.'];
    @got          = $backfill_manager->backfill_promo_codes();
    cmp_deeply(\@got, $expected, "No clients to process");

    my $mock_client = Test::MockObject->new();
    my ($mock_client_details, $got_client_changes, $mock_client_temp_changes, $expected_client_changes);
    $mock_client->mock('promo_code' => sub { return $mock_client_details->{'promo_code'} });
    $mock_client->mock(
        'myaffiliates_token' => sub { $_[1] ? $mock_client_temp_changes->{'myaffiliate_token'} = $_[1] : $mock_client_details->{'myaffiliate_token'} }
    );
    $mock_client->mock('has_funded'                         => sub { return $mock_client_details->{'funded'} });
    $mock_client->mock('loginid'                            => sub { return $mock_client_details->{'loginid'} });
    $mock_client->mock('myaffiliates_token_registered'      => sub { $mock_client_temp_changes->{'myaffiliates_token_registered'} = $_[1] });
    $mock_client->mock('promo_code_checked_in_myaffiliates' => sub { $mock_client_temp_changes->{'checked_in_myaffiliates'}       = $_[1] });
    $mock_client->mock('save'                               => sub { $got_client_changes = $mock_client_temp_changes });

    @mock_clients = ($mock_client);

    subtest 'promo code is not associated with an affiliate' => sub {
        $mock_myaffiliates_response = {"id_from_promo_code" => ""};
        $mock_client_details        = {
            "promo_code" => "CODE",
            "loginid"    => "CR900000"
        };
        $got_client_changes       = {};
        $mock_client_temp_changes = {};
        $expected_client_changes  = {"checked_in_myaffiliates" => 1};
        $expected                 = [$mock_client_details->{loginid} . ': promo code is not linked to an affiliate.'];
        @got                      = $backfill_manager->backfill_promo_codes();
        cmp_deeply($got_client_changes, $expected_client_changes, "client details updated correctly");
        cmp_deeply(\@got,               $expected,                "report generated sucessfully");
    };

    subtest 'applying promo code on funded account' => sub {
        $mock_myaffiliates_response = {
            "id_from_promo_code" => "AFFILIATE_ID_1",
            "id_from_token"      => "AFFILIATE_ID_1",

        };
        $mock_client_details = {
            "loginid"           => "CR90000",
            "promo_code"        => "CODE",
            "myaffiliate_token" => "AFFILIATE_TOKEN",
            "funded"            => 1
        };
        $got_client_changes       = {};
        $mock_client_temp_changes = {};
        $expected_client_changes  = {"checked_in_myaffiliates" => 1};
        $expected                 = [$mock_client_details->{loginid} . ': Account already funded, not updating token'];
        @got                      = $backfill_manager->backfill_promo_codes();
        cmp_deeply($got_client_changes, $expected_client_changes, "client details updated correctly");
        cmp_deeply(\@got,               $expected,                "report generated sucessfully");
    };

    subtest 'Promo code was applied' => sub {
        $mock_myaffiliates_response = {
            "id_from_promo_code" => "AFFILIATE_ID_1",
            "id_from_token"      => "",
            "token"              => "AFFILIATE_TOKEN_1"
        };
        $mock_client_details = {
            "loginid"           => "CR90000",
            "promo_code"        => "CODE",
            "myaffiliate_token" => "",
            "funded"            => 0
        };
        $got_client_changes       = {};
        $mock_client_temp_changes = {};
        $expected_client_changes  = {
            "checked_in_myaffiliates"       => 1,
            "myaffiliate_token"             => $mock_myaffiliates_response->{token},
            "myaffiliates_token_registered" => 0
        };
        $expected =
            [     $mock_client_details->{loginid}
                . ': had no token and was not funded. Usage of promocode added token '
                . $mock_myaffiliates_response->{token}];
        @got = $backfill_manager->backfill_promo_codes();
        cmp_deeply($got_client_changes, $expected_client_changes, "client details updated correctly");
        cmp_deeply(\@got,               $expected,                "report generated sucessfully");
    };

    subtest 'Promo code applied updates existing my affiliate token' => sub {
        $mock_myaffiliates_response = {
            "id_from_promo_code" => 10,
            "id_from_token"      => 20,
            "token"              => "AFFILIATE_TOKEN_1",
            "subordinate"        => 0
        };
        $mock_client_details = {
            "loginid"           => "CR90000",
            "promo_code"        => "CODE",
            "myaffiliate_token" => "AFFILIATE_TOKEN_2",
            "funded"            => 0
        };
        $got_client_changes       = {};
        $mock_client_temp_changes = {};
        $expected_client_changes  = {
            "checked_in_myaffiliates"       => 1,
            "myaffiliate_token"             => $mock_myaffiliates_response->{token},
            "myaffiliates_token_registered" => 0
        };
        $expected =
            [     $mock_client_details->{loginid}
                . ': had token but was not funded. Usage of promocode '
                . $mock_client_details->{promo_code}
                . ' replaced token with '
                . $mock_myaffiliates_response->{token}];
        @got = $backfill_manager->backfill_promo_codes();
        cmp_deeply($got_client_changes, $expected_client_changes, "client details updated correctly");
        cmp_deeply(\@got,               $expected,                "report generated sucessfully");
    };

    subtest 'Client already tracked. Not updating with subordinate token' => sub {
        $mock_myaffiliates_response = {
            "id_from_promo_code" => 10,
            "id_from_token"      => 20,
            "token"              => "AFFILIATE_TOKEN_1",
            "subordinate"        => 1
        };
        $mock_client_details = {
            "loginid"           => "CR90000",
            "promo_code"        => "CODE",
            "myaffiliate_token" => "AFFILIATE_TOKEN_2",
            "funded"            => 0
        };
        $got_client_changes       = {};
        $mock_client_temp_changes = {};
        $expected_client_changes  = {"checked_in_myaffiliates" => 1};
        $expected = [$mock_client_details->{'loginid'} . ': Already tracked by token, so not updating with subordinate promocode token.'];
        @got      = $backfill_manager->backfill_promo_codes();
        cmp_deeply($got_client_changes, $expected_client_changes, "client details updated correctly");
        cmp_deeply(\@got,               $expected,                "report generated sucessfully");
    };
    $mock_user_client->unmock_all();
    $mock_myaffiliates->unmock_all();
};

subtest 'is_backfill_pending' => sub {
    my (@mock_clients, $client_join_date, $expected, $current_date);
    my $mock_user_client = Test::MockModule->new("BOM::User::Client");
    $mock_user_client->redefine('by_promo_code' => sub { return @mock_clients });

    my $backfill_manager = BOM::MyAffiliates::BackfillManager->new(_available_broker_codes => ['CR']);
    my $mock_client      = Test::MockObject->new();
    $mock_client->mock('date_joined' => sub { return $client_join_date });

    $expected         = 1;
    $current_date     = "2022-12-08 10:12:59";
    $client_join_date = "2022-12-08 21:10:03";
    @mock_clients     = ($mock_client);
    is($backfill_manager->is_backfill_pending($current_date), $expected, "Client joined on the same date");

    $expected         = 0;
    $current_date     = "2022-12-08 10:00:00";
    $client_join_date = "2022-12-09 00:00:00";
    @mock_clients     = ($mock_client);
    is($backfill_manager->is_backfill_pending($current_date), $expected, "Client joined on a different date");
};

done_testing;
