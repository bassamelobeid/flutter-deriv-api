use Test::MockTime qw( restore_time set_fixed_time );
use Test::More $ENV{SKIP_MYAFFILIATES} ? (skip_all => 'SKIP_MYAFFILIATES set') : ('no_plan');
use Test::MockModule;
use Sub::Override;
use Test::Exception;
use DateTime;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::MyAffiliates::GenerateRegistrationDaily;
use BOM::Platform::MyAffiliates::BackfillManager;
use BOM::Platform::MyAffiliates::ExposureManager;
use BOM::Database::DataMapper::CollectorReporting;

alarm(1800);    #This is a long test. Avoid causing PANICTIMEOUT

########## Move me down, please ##
subtest "Sanity check" => sub {
    plan tests => 17;
    # Those tests rely on having a few tokens and promocodes and affiliates accounts with subordinate flags set on the MyAffiliate
    # platform. We just ensure it's still valid before proceeding with the tests.

    # non subordinate affiliates and tokens:
    is(BOM::Platform::MyAffiliates->new->is_subordinate_affiliate(2),                                     undef, "Affiliate 2 is NOT subordinate");
    is(BOM::Platform::MyAffiliates->new->get_affiliate_id_from_token('PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk'), 2,     "Affiliate 2 token");
    is(BOM::Platform::MyAffiliates->new->is_subordinate_promocode('BOM2009'),
        undef, "Promocode BOM2009 belongs to affiliate 2 which is a NOT a subordinate affiliate");

    is(BOM::Platform::MyAffiliates->new->is_subordinate_affiliate(6),                                     undef, "Affiliate 6 is NOT subordinate");
    is(BOM::Platform::MyAffiliates->new->get_affiliate_id_from_token('jGZUKO3JWgyVAv0U_Fv2nVOqZLGcUW5p'), 6,     "Affiliate 6 token");

    # subordinate affiliates and tokens
    is(BOM::Platform::MyAffiliates->new->is_subordinate_affiliate(13), 1, "Affiliate 13 is subordinate");
    is(BOM::Platform::MyAffiliates->new->is_subordinate_promocode('0013F10'),
        1, "Promocode 0013F10 belongs to affiliate 13 which is a subordinate affiliate");
    is(BOM::Platform::MyAffiliates->new->get_affiliate_id_from_token('k7a3BtGf-EjKto_EPcZApGNd7ZgqdRLk'), 13, "Affiliate 13 token");

    is(BOM::Platform::MyAffiliates->new->is_subordinate_affiliate(274),                                   1,   "Affiliate 274 is subordinate");
    is(BOM::Platform::MyAffiliates->new->get_affiliate_id_from_token('7O0pu16F5bbKto_EPcZApGNd7ZgqdRLk'), 274, "Affiliate 274 token");

    # Let's also make sure that new accounts are considered not-funded
    # and that they get reported when they have the myaffiliates_token_registered
    # set to false
    my $client;
    my $is_new_client_reported;

    # with no token
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
    }
    "create new client success";

    is($client->has_funded, 0, "Client not funded");
    $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is($is_new_client_reported, 0, "Created client is not on the new-registrations list to report to my affiliates");

    # with token
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code        => 'CR',
            myaffiliates_token => 'jGZUKO3JWgyVAv0U_Fv2nVOqZLGcUW5p',
        });
    }
    "create new client success";

    is($client->has_funded, 0, "Client not funded");

    $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is($is_new_client_reported, 1, "Created client is now on the new-registrations list to report to my affiliates");

    $client->myaffiliates_token_registered(1);
    $client->save;

    $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is($is_new_client_reported, 0, "Created client is no longer on the new-registrations list to report to my affiliates");
};

subtest "promocode processing rules: handling usage of promocode and it's updating of tokens" => sub {
    plan tests => 5;

    my $client;
    my $is_new_client_reported;
    my $is_updated_by_backfill;

    subtest "-funded +token -> promo => promo" => sub {
        plan tests => 5;
        lives_ok {
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code        => 'CR',
                myaffiliates_token => 'jGZUKO3JWgyVAv0U_Fv2nVOqZLGcUW5p',
            });
        }
        "create new client success";

        $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
        is $is_updated_by_backfill, 0, "Backfill reports that it didn't update our client";
        $client->myaffiliates_token_registered(1);
        $client->promo_code('BOM2009');
        $client->save;

        $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
        is $is_updated_by_backfill, 1, "Backfill reports that it updated our client";
        $client->load;
        is $client->myaffiliates_token, 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk', 'token replaced';

        $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
        is($is_new_client_reported, 1, "Created client is on the new-registrations list to report to my affiliates");
    };

    subtest "-funded -token -> promo => promo" => sub {
        plan tests => 5;
        lives_ok {
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });
        }
        "create new client success";
        $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
        is $is_updated_by_backfill, 0, "Backfill reports that it didn't update our client";

        $client->promo_code('BOM2009');
        $client->save;

        $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
        is $is_updated_by_backfill, 1, "Backfill reports that it updated our client";
        $client->load;
        is $client->myaffiliates_token, 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk', 'token added to existing client';

        $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
        is($is_new_client_reported, 1, "Created client is on the new-registrations list to report to my affiliates");
    };

    subtest "-funded -token -> sub_promo => sub_promo" => sub {
        plan tests => 5;
        lives_ok {
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
            });
        }
        "create new client success";

        $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
        is $is_updated_by_backfill, 0, "Backfill reports that it didn't update our client";

        $client->promo_code('0013F10');
        $client->save;

        $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
        is $is_updated_by_backfill, 1, "Backfill reports that it updated our client";
        $client->load;
        is $client->myaffiliates_token, 'k7a3BtGf-EjKto_EPcZApGNd7ZgqdRLk', 'token added to existing client with subordinate promocode';

        $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
        is($is_new_client_reported, 1, "Created client is on the new-registrations list to report to my affiliates");
    };

    subtest "-funded +token -> sub_promo => token" => sub {
        plan tests => 5;
        lives_ok {
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code        => 'CR',
                myaffiliates_token => '7O0pu16F5bbKto_EPcZApGNd7ZgqdRLk',
            });
        }
        "create new client success";

        $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
        is $is_updated_by_backfill, 0, "Backfill reports that it didn't update our client";
        $client->myaffiliates_token_registered(1);
        $client->promo_code('0013F10');
        $client->save;

        $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
        is $is_updated_by_backfill, 1, "Backfill reports that it updated our client";
        $client->load;
        is $client->myaffiliates_token, '7O0pu16F5bbKto_EPcZApGNd7ZgqdRLk', 'token not replaced';

        $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
        is($is_new_client_reported, 0, "Created client is not on the new-registrations list to report to my affiliates");
    };

    # all others
    subtest "+funded +-token -> (sub_)promo => +-token" => sub {
        plan tests => 6;
        foreach my $initial_token ('7O0pu16F5bbKto_EPcZApGNd7ZgqdRLk', 'jGZUKO3JWgyVAv0U_Fv2nVOqZLGcUW5p', undef) {
            foreach my $promocode ('BOM2009', '0013F10') {
                subtest "using: token => " . ($initial_token or 'undef') . ", promocode => $promocode" => sub {
                    plan tests => 6;
                    lives_ok {
                        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                            broker_code        => 'CR',
                            myaffiliates_token => $initial_token,
                        });
                    }
                    "create new client success";

                    my $is_updated_by_backfill =
                        grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
                    is $is_updated_by_backfill, 0, "Backfill reports that it didn't update our client";

                    $client->myaffiliates_token_registered(1);

                    lives_ok {
                        my $account = $client->set_default_account('USD');

                        $client->payment_legacy_payment(
                            currency     => 'USD',
                            amount       => 121.21,
                            remark       => 'here is money',
                            payment_type => 'credit_debit_card',
                        );
                    }
                    "deposit for client";

                    $client->promo_code($promocode);
                    $client->save;

                    $is_updated_by_backfill =
                        grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
                    is $is_updated_by_backfill, 1, "Backfill reports that it updated our client";
                    $client->load;
                    is $client->myaffiliates_token, $initial_token, 'token not replaced';

                    $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
                    is($is_new_client_reported, 0, "Created client is not on the new-registrations list to report to my affiliates");
                };
            }
        }
    };
};

subtest 'Marketing campaign: Client registers with Affiliate token from cookie and types a subordinate promocode' => sub {
    plan tests => 9;
    my $client;
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code        => 'CR',
            myaffiliates_token => 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk',
        });

        $client->promo_code('0013F10');
        $client->save;
    }
    "create new client with token and subordinate promocode";

    is $client->promo_code,                    '0013F10',                          "promocode set";
    is $client->myaffiliates_token,            'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk', "MyAffiliate token set";
    is $client->myaffiliates_token_registered, 0,                                  "token not yet registered!";

    my $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is $is_new_client_reported, 0, "Created client not yet on the new-registrations list to report to my affiliates";

    my $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
    is $is_updated_by_backfill, 1, "Backfill reports that it updated our client";

    is $client->myaffiliates_token, 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk', "MyAffiliate token not modified by backfill manager";
    is $client->promo_code, '0013F10', "promocode was also not modified";
    $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is($is_new_client_reported, 1, "Created client is now on the new-registrations list to report to my affiliates");
};

subtest 'Marketing campaign: Client registers with a subordinate affiliates token from cookie and types a promocodes' => sub {
    plan tests => 9;
    my $client;
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code        => 'CR',
            myaffiliates_token => 'k7a3BtGf-EjKto_EPcZApGNd7ZgqdRLk',
        });

        $client->promo_code('BOM2009');
        $client->save;
    }
    "create new client with subordinate token and promocode";

    is $client->promo_code,                    'BOM2009',                          "promocode set";
    is $client->myaffiliates_token,            'k7a3BtGf-EjKto_EPcZApGNd7ZgqdRLk', "MyAffiliate token set";
    is $client->myaffiliates_token_registered, 0,                                  "token not yet registered!";

    my $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is $is_new_client_reported, 0, "Created client not yet on the new-registrations list to report to my affiliates";

    my $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
    is $is_updated_by_backfill, 1, "Backfill reports that it updated our client";

    $client->load;
    is $client->myaffiliates_token, 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk',
        "registration token (subordinate) replaced with promocode's token by backfill manager";
    is $client->promo_code, 'BOM2009', "promocode was not modified";
    $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is($is_new_client_reported, 1, "Created client is on the new-registrations list to report to my affiliates");
};

subtest 'registering a client with a promocode and no token' => sub {
    plan tests => 9;

    # Create an account that uses a MyAffiliate promocode
    my $client;
    set_fixed_time(1286705410);    # 2010-10-10T10:10:10Z
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $client->promo_code('BOM2009');
        $client->save;
    }
    "create new client success";

    restore_time();

    is $client->promo_code,                    'BOM2009', "promocode set";
    is $client->myaffiliates_token,            undef,     "MyAffiliate token empty";
    is $client->myaffiliates_token_registered, 0,         "token not yet registered!";

    my $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is $is_new_client_reported, 0, "Created client not yet on the new-registrations list to report to my affiliates";

    my $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
    is $is_updated_by_backfill, 1, "Backfill reports that it updated our client's token";

    $client->load;
    is $client->myaffiliates_token, 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk', "MyAffiliate token set by BackfillManager";

    ($is_new_client_reported) = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    ok(defined $is_new_client_reported, "Created client is on the new-registrations list to report to my affiliates");
    is($is_new_client_reported->{date_joined}, '2010-10-10 10:10:10', "correct date reported");
};

subtest 'registering a client with an affiliate token and no promocode' => sub {
    plan tests => 8;

    my $client;
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code        => 'CR',
            myaffiliates_token => 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk',
        });
    }
    "create new client success";

    is $client->promo_code,                    undef,                              "promocode unset";
    is $client->myaffiliates_token,            'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk', "MyAffiliate token set";
    is $client->myaffiliates_token_registered, 0,                                  "token not yet registered!";

    my $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is($is_new_client_reported, 1, "Created client is on the new-registrations list to report to my affiliates");

    my $is_updated_by_backfill = grep { my $l = $client->loginid; /$l/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
    is $is_updated_by_backfill, 0, "Backfill didn't process our client. We have no promocode.";

    $client->load;
    is $client->myaffiliates_token, 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk', "MyAffiliate token still set after BackfillManager";
    $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is($is_new_client_reported, 1, "Created client is still on the new-registrations list to report to my affiliates");
};

subtest 'registering a client with both an affiliate token and a promocode' => sub {
    plan tests => 8;

    my $client;
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code        => 'CR',
            myaffiliates_token => 'aaaaaaaaaaaaaa_bbbbbbbbbbbbbbbbb',
        });

        $client->promo_code('BOM2009');
        $client->save;
    }
    "create new client success";

    #Then reload the client from the DB to be sure
    $client = BOM::Platform::Client::get_instance({'loginid' => $client->loginid});

    is $client->promo_code,                    'BOM2009',                          "promocode set";
    is $client->myaffiliates_token,            'aaaaaaaaaaaaaa_bbbbbbbbbbbbbbbbb', "MyAffiliate token empty";
    is $client->myaffiliates_token_registered, 0,                                  "token not yet registered!";

    my $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is $is_new_client_reported, 0, "Created client not yet on the new-registrations list to report to my affiliates";

    my $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
    is $is_updated_by_backfill, 1, "Backfill reports that it updated our client's token";

    $client->load;
    is $client->myaffiliates_token, 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk', "MyAffiliate token set by BackfillManager";
    $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is($is_new_client_reported, 1, "Created client is on the new-registrations list to report to my affiliates");
};

subtest 'registering a client without token and promocode' => sub {
    plan tests => 6;

    my $client;
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
    }
    "create new client success";

    is $client->promo_code,                    undef, "promocode empty";
    is $client->myaffiliates_token,            undef, "MyAffiliate token empty";
    is $client->myaffiliates_token_registered, 0,     "token not yet registered!";
    my $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is $is_new_client_reported, 0, "Created client not on the new-registrations list to report to my affiliates";

    my $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
    is $is_updated_by_backfill, 0, "Backfill does not update our client's token";
};

subtest 'using a promocode after registering without a token/promocode' => sub {
    plan tests => 10;

    set_fixed_time(1293888600);    # 2011-01-01T13:30:00Z
    my $client;
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
    }
    "create new client success";

    is $client->promo_code,                    undef, "no promocode";
    is $client->myaffiliates_token,            undef, "MyAffiliate token empty";
    is $client->myaffiliates_token_registered, 0,     "token not yet registered!";

    my $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is $is_new_client_reported, 0, "Created client not on the new-registrations list to report to my affiliates";

    set_fixed_time(1296656400);    # 2011-02-02T14:20:00Z
    $client->promo_code('BOM2009');
    $client->promo_code_status('APPROVAL');
    $client->promo_code_apply_date(Date::Utility->new->db_timestamp);
    ok $client->save, "added promocode";

    my $is_updated_by_backfill = grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes;
    is $is_updated_by_backfill, 1, "Backfill reports that it updated our client's token";

    $client->load;
    is $client->myaffiliates_token, 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk', "MyAffiliate token set by BackfillManager";
    ($is_new_client_reported) = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    ok(defined $is_new_client_reported, "Created client is on the new-registrations list to report to my affiliates");
    is($is_new_client_reported->{date_joined}, Date::Utility->new->db_timestamp,
        "reporting the correct promocode apply_date and not the joined_date");
    restore_time();
};

subtest "create account without token, get exposed to creative media then funded" => sub {
    plan tests => 13;

    my $client;
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            date_joined => '2007-06-05 04:03:02',
        });
    }
    "create new client success";

    is $client->promo_code,                    undef, "promocode empty";
    is $client->myaffiliates_token,            undef, "MyAffiliate token empty";
    is $client->myaffiliates_token_registered, 0,     "token not yet registered!";

    my $is_new_client_reported = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    is $is_new_client_reported, 0, "Created client not on the new-registrations list to report to my affiliates";

    my $is_updated_by_mark_new_deposits =
        grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->mark_first_deposits;
    is $is_updated_by_mark_new_deposits, 0, ".. and is not updated by mark_new_deposits";

    set_fixed_time('2008-09-10T11:12:13Z');
    my $manager = BOM::Platform::MyAffiliates::ExposureManager->new(client => $client);
    $manager->add_exposure(
        BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure->new(
            client               => $client,
            myaffiliates_token   => 'jGZUKO3JWgyVAv0U_Fv2nS0plL73saAE',
            exposure_record_date => DateTime->now()));
    $manager->save;
    is($manager->creative_affiliate_id, 6, '.. then client gets exposed to creative media..');
    restore_time();

    lives_ok {
        my $account = $client->set_default_account('USD');

        $client->payment_legacy_payment(
            currency         => 'USD',
            amount           => 121.21,
            remark           => 'here is money',
            payment_type     => 'credit_debit_card',
            transaction_time => '2009-10-11 20:21:00',
            payment_time     => '2009-10-11 20:21:00'
        );
    }
    'deposit for client';

    is($client->has_funded,             1, '.. and then funded');
    is($manager->creative_affiliate_id, 6, '.. so we correctly tag that affiliate as being the creative affiliate for that account');

    $is_updated_by_mark_new_deposits =
        grep { my $l = $client->loginid; /^$l:/ } BOM::Platform::MyAffiliates::BackfillManager->new->mark_first_deposits;
    is $is_updated_by_mark_new_deposits, 1, ".. and mark_first_deposits updates our client!";

    ($is_new_client_reported) = grep { $_->{loginid} eq $client->loginid } @{unregistered_list()};
    ok defined $is_new_client_reported, "and, finally, the creative media exposure is on the new-registrations list to report to my affiliates";
    is $is_new_client_reported->{date_joined}, '2009-10-11 20:21:00', "date reported correctly";
};

subtest signup_override => sub {
    plan tests => 5;

    my $aug_1st = Date::Utility->new('2011-08-01 12:00:00');

    # client opens account with myaffiliates_token
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code        => 'CR',
            myaffiliates_token => 's1gNuPoVeRr1dEs1gNuPoVeRr1dEs1gN',
            date_joined        => $aug_1st->db_timestamp,
        });
    }
    "create new client success";

    my $report = BOM::Platform::MyAffiliates::GenerateRegistrationDaily->new(requested_date => $aug_1st);

    # report for that day has that token
    my $new_client_reported =
        scalar grep { $_->{loginid} eq $client->loginid and $_->{myaffiliates_token} eq 's1gNuPoVeRr1dEs1gNuPoVeRr1dEs1gN' } @{$report->new_clients};

    is($new_client_reported, 1, 'New client is in report.');

    $report->register_tokens;    # mark all pending registrations as registered on our end.

    my $aug_2nd = Date::Utility->new('2011-08-02 12:00:00');
    set_fixed_time($aug_2nd->epoch);

    # add sign_up replacement token
    my $expmgr = BOM::Platform::MyAffiliates::ExposureManager->new(client => $client);
    $expmgr->add_exposure(
        BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure->new(
            client               => $client,
            myaffiliates_token   => 's2gNuPoVeRr2dEs2gNuPoVeRr2dEs2gN',
            signup_override      => 1,
            exposure_record_date => DateTime->now(),                      # .. ensure mocked time comes from this test pgm not from db
        ));
    $expmgr->save;

    # try to add same token again later.
    set_fixed_time($aug_2nd->epoch + 600);

    throws_ok {
        $expmgr->add_exposure(
            BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure->new(
                client             => $client,
                myaffiliates_token => 's2gNuPoVeRr2dEs2gNuPoVeRr2dEs2gN',
                signup_override    => 1,
            ));
    }

    qr/already has signup_override token/, 'Cannot add same signup_override token more than once.';

    $report = BOM::Platform::MyAffiliates::GenerateRegistrationDaily->new(requested_date => $aug_2nd);

    # run report for that day, verify signup token is there (dated at time of addition).
    my $signup_override_reported =
        scalar grep { $_->{loginid} eq $client->loginid and $_->{myaffiliates_token} eq 's2gNuPoVeRr2dEs2gNuPoVeRr2dEs2gN' } @{$report->new_clients};

    is($signup_override_reported, 1, 'Signup override is in report.');

    $report->register_tokens;

    # verify that the override is no longer in report
    my $aug_3rd = Date::Utility->new('2011-08-03 12:00:00');
    $report = BOM::Platform::MyAffiliates::GenerateRegistrationDaily->new(requested_date => $aug_3rd);
    $signup_override_reported =
        scalar grep { $_->{loginid} eq $client->loginid and $_->{myaffiliates_token} eq 's2gNuPoVeRr2dEs2gNuPoVeRr2dEs2gN' } @{$report->new_clients};

    is($signup_override_reported, 0, 'Signup override already reported, so not in future report.');
};

subtest 'backfill pending' => sub {
    plan tests => 8;

    is(BOM::Platform::MyAffiliates::BackfillManager->new->is_backfill_pending, 0, "No promocodes to be backfilled");

    lives_ok {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code        => 'CR',
            myaffiliates_token => 'PQ4YXsO2q5nKto_EPcZApGNd7ZgqdRLk',
        });
    }
    "create client without promocode";
    is(BOM::Platform::MyAffiliates::BackfillManager->new->is_backfill_pending, 0, "Still no promocode pending to be backfilled");

    lives_ok {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            date_joined => Date::Utility->new->db_timestamp,
        });

        $client->promo_code('BOM2009');
        $client->save;
    }
    "create client with promocode";

    is(BOM::Platform::MyAffiliates::BackfillManager->new->is_backfill_pending, 1, "Promocodes pending to be backfilled");
    use DateTime;
    is(BOM::Platform::MyAffiliates::BackfillManager->new->is_backfill_pending(DateTime->today->subtract(days => 1)->ymd),
        0, "No promocodes pending to be backfilled if we consider only up to yesterday");

    ok(BOM::Platform::MyAffiliates::BackfillManager->new->backfill_promo_codes, "Promocodes backfilled.");
    is(BOM::Platform::MyAffiliates::BackfillManager->new->is_backfill_pending, 0, "No promocodes pending to be backfilled");
};

sub unregistered_list {
    my $date_to       = Date::Utility->new(time + 1)->datetime_yyyymmdd_hhmmss;
    my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
        operation   => 'collector'
    });
    return $report_mapper->get_unregistered_client_token_pairs_before_datetime($date_to);
}
