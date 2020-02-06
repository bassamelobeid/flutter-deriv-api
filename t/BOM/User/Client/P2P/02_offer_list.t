use strict;
use warnings;

use Test::More;
use Test::Fatal;

use BOM::User::Client;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;

my $app_config = BOM::Config::Runtime->instance->app_config;
my $max_order  = $app_config->payments->p2p->limits->maximum_order;

BOM::Test::Helper::P2P::create_escrow();
my ($agent1, $offer1) = BOM::Test::Helper::P2P::create_offer(amount => 100);
my ($agent2, $offer2) = BOM::Test::Helper::P2P::create_offer(amount => 100);
my $client = BOM::Test::Helper::P2P::create_client();

subtest 'agent offers' => sub {
    like(
        exception {
            $client->p2p_agent_offers()
        },
        qr/AgentNotRegistered/,
        "non agent gets error"
    );

    $agent2->p2p_agent_update(is_active => 0);

    is $agent1->p2p_agent_offers()->[0]{offer_id}, $offer1->{offer_id}, 'agent 1 (active) gets offer';
    is $agent1->p2p_agent_offers()->@*, 1, 'agent 1 got one';
    is $agent2->p2p_agent_offers()->[0]{offer_id}, $offer2->{offer_id}, 'agent 2 (inactive) gets offer';
    is $agent2->p2p_agent_offers()->@*, 1, 'agent 2 got one';
};


subtest 'amount filter' => sub {
    plan skip_all => "We don't filter offer list for now, but might do later";

    is $client->p2p_offer_list()->@*, 1, 'No filter gets offer';
    is $client->p2p_offer_list(amount => 101)->@*, 0, 'Filter out >amount';
    is $client->p2p_offer_list(amount => 99)->@*,  1, 'Not filter out <amount';

    $agent1->p2p_offer_update(
        offer_id   => $offer1->{offer_id},
        max_amount => 90
    );
    is $client->p2p_offer_list(amount => 91)->@*, 0, 'Filter out >max';
    is $client->p2p_offer_list(amount => 89)->@*, 1, 'Not filter out <max';

    BOM::Test::Helper::P2P::create_order(
        offer_id => $offer1->{offer_id},
        amount   => 20
    );    # offer remaining is now 80
    is $client->p2p_offer_list(amount => 81)->@*, 0, 'Filter out >remaining';
    is $client->p2p_offer_list(amount => 79)->@*, 1, 'Not filter out <remaining';

    $app_config->payments->p2p->limits->maximum_order(70);
    is $client->p2p_offer_list(amount => 71)->@*, 0, 'Filter out >config max';
    is $client->p2p_offer_list(amount => 69)->@*, 1, 'Not filter out <config max';
};

BOM::Test::Helper::P2P::reset_escrow();

# restore app config
$app_config->payments->p2p->limits->maximum_order($max_order);

done_testing();
