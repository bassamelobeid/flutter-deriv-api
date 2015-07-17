# This test calls code that uses various MyAffiliates APIs, so if they are not accessable for any reason then the tests may fail.
# They also rely on specific test data set up in the MyAffiliates backend. If this data was to change, again the tests may break.

use List::Util qw( first );
use Test::Exception;
use Test::MockObject::Extends;
use Test::More skip_all => 'this functionality deprecated';
use Test::NoWarnings;

use DateTime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure;
use BOM::Platform::MyAffiliates;
use BOM::Platform::Client;
use BOM::Platform::MyAffiliates::BackfillManager;
use BOM::Platform::MyAffiliates::ExposureManager;

my $aff = BOM::Platform::MyAffiliates->new;

subtest 'mark_first_deposits method.' => sub {
    plan tests => 6;

    my $client = BOM::Platform::Client->new({loginid => 'CR2002'});
    my $account = $client->default_account;

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 5000,
        remark   => 'here is money',
    );

    $client = BOM::Platform::Client::get_instance({loginid => $client->loginid});
    my $expmgr = BOM::Platform::MyAffiliates::ExposureManager->new(client => $client);

    my @clients_exposures = $expmgr->_get_exposures;
    is(scalar @clients_exposures, 0, 'Client starts with no exposures at all.');

    my $exposure_with_creative_media_record_date = DateTime->new(
        year   => 2004,
        month  => 8,
        day    => 1,
        hour   => 10,
        minute => 40
    );

    # This token contains media with creative_affiliate_id = 6
    $expmgr->add_exposure(
        BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure->new(
            myaffiliates_token   => 'PQ4YXsO2q5mVAv0U_Fv2nS0plL73saAE',
            client               => $client,
            exposure_record_date => $exposure_with_creative_media_record_date,
        ));

    @clients_exposures = $expmgr->_get_exposures;
    is(scalar @clients_exposures, 1, 'After adding an exposure, we expect the client to have one exposure.');

    is($expmgr->creative_affiliate_id, 6, "$client is able to identify that its creative_affiliate_id is 6.");

    # make sure added exposure is saved to DB
    $expmgr->save;

    # Do backfill
    my $backfill_manager = BOM::Platform::MyAffiliates::BackfillManager->new;
    $backfill_manager->mark_first_deposits;

    @clients_exposures = $expmgr->_get_exposures;
    is(scalar @clients_exposures, 2, 'Backfill manager should have added a second exposure (the creative exposure).');

    my $creative_exposure = first { $_->pay_for_exposure } @clients_exposures;

    my $pay_for_affiliate_id = $aff->get_affiliate_id_from_token($creative_exposure->myaffiliates_token);

    is($pay_for_affiliate_id, 6, 'Exposure marked "pay for" has token containing affiliate_id 6');

    is(
        $creative_exposure->exposure_record_date->epoch,
        $client->first_funded_date->epoch,
        'creative exposure should have same record date as initial exposure that it was derived from.'
    );
};

subtest 'backfill_promo_codes' => sub {
    plan tests => 6;

    my $backfill_manager = BOM::Platform::MyAffiliates::BackfillManager->new;
    {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $client->promo_code('BOM2009');
        is($client->promo_code_checked_in_myaffiliates, 0, "$client promo code not yet checked.");
        $client->save;

        $backfill_manager->backfill_promo_codes;

        $client = BOM::Platform::Client->new({loginid => $client->loginid});
        is($client->promo_code_checked_in_myaffiliates, 1,  "After backfilling promo codes, $client promo code has been checked.");
        is(length $client->myaffiliates_token,          32, "$client MyAffiliates token is set.");
        my $promo_code_affiliate_id = $aff->get_affiliate_id_from_token($client->myaffiliates_token);
        is($promo_code_affiliate_id, 2, 'promo code BOM2009 is mapped to affiliate id 2.');
    }

    # since this token has a specified media_id, it will be different than the generic
    # token that would be set for a promo-code (which wouldn't contain media_id).
    my $cookied_token = $aff->get_token({
        affiliate_id => 2,
        media_id     => 2
    });

    {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $client->myaffiliates_token($cookied_token);
        # BOM2009 is linked to the same affiliate (id 2).
        $client->promo_code('BOM2009');
        $client->promo_code_checked_in_myaffiliates(0);
        $client->save;

        $backfill_manager->backfill_promo_codes;

        $client = BOM::Platform::Client->new({loginid => $client->loginid});
        is($client->promo_code_checked_in_myaffiliates, 1, "After backfilling promo codes, $client promo code has been checked.");
        is($client->myaffiliates_token, $cookied_token, "$client MyAffiliates token has not changed.");
    }
};

subtest 'get_token throw' => sub {
    plan tests => 1;

    $aff = Test::MockObject::Extends->new($aff);
    $aff->mock('get_default_plan', sub { return; });

    throws_ok { $aff->get_token({affiliate_id => 1234}) } qr/Unable to get Setup ID for affiliate/, 'Throws when we cannot get Setup ID.';
};

