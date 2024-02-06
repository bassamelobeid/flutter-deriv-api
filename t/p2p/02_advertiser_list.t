use strict;
use warnings;

use Test::More;
use Test::Deep;

use BOM::Config::Redis;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new();

BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);
BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);
BOM::Test::Helper::P2P::create_escrow();
BOM::Test::Helper::P2P::bypass_sendbird();

my $partners;

sub _model_result {
    my $partner_list = shift;
    $partners = {};
    foreach my $partner ($partner_list->@*) {
        $partners->{$partner->{id}} = {
            name               => $partner->{name},
            basic_verification => $partner->{basic_verification},
            full_verification  => $partner->{full_verification},
            is_blocked         => $partner->{is_blocked},
            first_name         => $partner->{first_name},
            last_name          => $partner->{last_name}};
    }
}

subtest 'advertiser trade partners' => sub {
    my ($advertiser0, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => 100,
        max_order_amount => 100,
        type             => 'sell'
    );
    my $advertiser1 = BOM::Test::Helper::P2P::create_advertiser(
        client_details => {
            first_name => 'mary',
            last_name  => 'jane'
        });
    my $advertiser2 = BOM::Test::Helper::P2P::create_advertiser(
        client_details => {
            first_name => 'john',
            last_name  => 'smith'
        });

    is scalar $advertiser1->p2p_advertiser_list(trade_partners => 1)->@*, 0, "There is no partners for advertiser1";

    $advertiser1->p2p_advertiser_relations(add_blocked => [$advertiser2->p2p_advertiser_info->{id}]);

    is scalar $advertiser1->p2p_advertiser_list(trade_partners => 1)->@*, 1, "There is 1 trade partner for advertiser1 with relation";

    my $partner_list = $advertiser1->p2p_advertiser_list(trade_partners => 1);
    cmp_deeply([{
                id                 => $partner_list->[0]->{id},
                name               => $partner_list->[0]->{name},
                basic_verification => $partner_list->[0]->{basic_verification},
                full_verification  => $partner_list->[0]->{full_verification},
                is_blocked         => $partner_list->[0]->{is_blocked},
                first_name         => $partner_list->[0]->{first_name},
                last_name          => $partner_list->[0]->{last_name}

            }
        ],
        [{
                id                 => 3,
                name               => 'test advertiser 103',
                basic_verification => 0,
                full_verification  => 0,
                is_blocked         => 1,
                first_name         => undef,                   #when show_name is false then first_name is undef
                last_name          => undef                    #when show_name is false then last_name is undef

            }
        ],
        'correct values for first trade partner'
    );

    $advertiser1->p2p_order_create(
        advert_id   => $advert_info->{id},
        amount      => $advert_info->{amount},
        rule_engine => $rule_engine,

    );

    is scalar $advertiser1->p2p_advertiser_list(trade_partners => 1)->@*, 2,
        "There is two partners for advertiser1, 1 with relation and 1 with order";

    $partner_list = $advertiser1->p2p_advertiser_list(trade_partners => 1);
    _model_result($partner_list);

    cmp_deeply(
        $partners,
        {
            3 => {
                name               => 'test advertiser 103',
                basic_verification => 0,
                full_verification  => 0,
                is_blocked         => 1,
                first_name         => undef,                   #when show_name is false then first_name is undef
                last_name          => undef                    #when show_name is false then last_name is undef

            },
            1 => {
                name               => 'test advertiser 101',
                basic_verification => 0,
                full_verification  => 0,
                is_blocked         => 0,
                first_name         => undef,                   #when show_name is false then first_name is undef
                last_name          => undef                    #when show_name is false then last_name is undef
            }
        },
        'correct values for first trade partner'
    );

    $advertiser0->client->status->set('age_verification', 'system', 'testing');
    $advertiser0->client->set_authentication('ID_ONLINE', {status => 'pass'});

    $partner_list = $advertiser1->p2p_advertiser_list(trade_partners => 1);
    _model_result($partner_list);

    cmp_deeply(
        $partners,
        {
            3 => {
                name               => 'test advertiser 103',
                basic_verification => 0,
                full_verification  => 0,
                is_blocked         => 1,
                first_name         => undef,                   #when show_name is false then first_name is undef
                last_name          => undef                    #when show_name is false then last_name is undef

            },
            1 => {
                name               => 'test advertiser 101',
                basic_verification => 1,
                full_verification  => 1,
                is_blocked         => 0,
                first_name         => undef,                   #when show_name is false then first_name is undef
                last_name          => undef                    #when show_name is false then last_name is undef
            }
        },
        'correct values for updated verifications'
    );

    $advertiser0->p2p_advertiser_update(show_name => 1);
    $partner_list = $advertiser1->p2p_advertiser_list(trade_partners => 1);
    _model_result($partner_list);

    cmp_deeply(
        $partners,
        {
            3 => {
                name               => 'test advertiser 103',
                basic_verification => 0,
                full_verification  => 0,
                is_blocked         => 1,
                first_name         => undef,                   #when show_name is false then first_name is undef
                last_name          => undef                    #when show_name is false then last_name is undef

            },
            1 => {
                name               => 'test advertiser 101',
                basic_verification => 1,
                full_verification  => 1,
                is_blocked         => 0,
                first_name         => 'bRaD',                  #when show_name is true then first_name is visible
                last_name          => 'pItT'                   #when show_name is true then last_name is visible
            }
        },
        'correct values for updated verifications'
    );
};

done_testing;
