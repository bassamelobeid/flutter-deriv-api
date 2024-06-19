use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::TradingPlatform::Helper::HelperDerivEZ;
use BOM::Test::Helper::FinancialAssessment;
use JSON::MaybeUTF8;
use Test::More;
use Test::MockModule;

subtest 'is FA complete' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $user   = BOM::User->create(
        email    => 'facomplete@derivez.com',
        password => 'test'
    )->add_client($client);

    $client->user($user);
    $client->binary_user_id($user->id);

    my $args = {
        client                            => $client,
        group                             => 'demo',
        financial_assessment_requirements => 0,
    };

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 1, 'Expected result for a group starting with demo';

    $args->{group} = 'mydemo';                   # not starting with demo
    $client->aml_risk_classification('high');    # set client as high to make the FA required

    ok !$client->is_financial_assessment_complete(), 'FA not completed';
    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), $client->is_financial_assessment_complete(),
        'Expected result when financial_assessment_requirements is falsey and group does not start with demo';

    $args->{financial_assessment_requirements} = [qw/financial_information/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), $client->is_financial_assessment_complete(),
        'Expected result when checking financial_information on a svg client (no FA)';

    $args->{financial_assessment_requirements} = [qw/financial_information trading_experience/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), $client->is_financial_assessment_complete(),
        'Expected result when checking financial_information and trading_experience on a svg client (no FA)';

    # switch to maltainvest
    $client->broker('MF');

    $args->{financial_assessment_requirements} = [qw/financial_information/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), $client->is_financial_assessment_complete(),
        'Expected result when checking financial_information on a maltainvest client (no FA)';

    $args->{financial_assessment_requirements} = [qw/financial_information trading_experience/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), $client->is_financial_assessment_complete(),
        'Expected result when checking financial_information and trading_experience on a maltainvest client (no FA)';

    # back to svg
    $client->broker('CR');

    # give FA
    my $fa = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
    $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8($fa)});

    $args->{financial_assessment_requirements} = [qw/financial_information/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 1,
        'Expected result when checking financial_information on a svg client (with FA)';

    $args->{financial_assessment_requirements} = [qw/trading_experience/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 1,
        'Expected result when checking trading_experience on a svg client (with FA)';

    $args->{financial_assessment_requirements} = [qw/financial_information trading_experience/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 1,
        'Expected result when checking financial_information an trading_experience on a svg client (with FA)';

    # switch to maltainvest
    $client->broker('MF');

    $args->{financial_assessment_requirements} = [qw/financial_information/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 1,
        'Expected result when checking financial_information on a maltainvest client (with FA)';

    $args->{financial_assessment_requirements} = [qw/trading_experience/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 1,
        'Expected result when checking trading_experience on a maltainvest client (with FA)';

    $args->{financial_assessment_requirements} = [qw/financial_information trading_experience/];

    is BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 1,
        'Expected result when checking financial_information an trading_experience on a maltainvest client (with FA)';

    subtest 'more complicated scenarios' => sub {
        my $mock_fa  = Test::MockModule->new('BOM::User::FinancialAssessment');
        my $sections = {};

        $mock_fa->mock(
            'is_section_complete',
            sub {
                my (undef, $section) = @_;

                return $sections->{$section};
            });

        my $mock_cli = Test::MockModule->new(ref($client));

        $mock_cli->mock(
            'is_financial_assessment_complete',
            sub {
                return 0;
            });

        my $args = {
            client                            => $client,
            group                             => 'notdemo',
            financial_assessment_requirements => [qw/financial_information trading_experience/],
        };

        $sections->{financial_information} = 0;
        $sections->{trading_experience}    = 1;
        $client->broker('MF');

        ok !BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 'maltainvest client needs both FI and TE';

        $sections->{financial_information} = 0;
        $sections->{trading_experience}    = 1;
        $client->broker('CR');

        ok !BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 'svg client needs FI';

        $sections->{financial_information} = 1;
        $sections->{trading_experience}    = 0;
        $client->broker('MF');
        ok !BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 'maltainvest client needs both FI and TE';

        $sections->{financial_information} = 1;
        $sections->{trading_experience}    = 0;
        $client->broker('CR');

        ok BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 'svg is complete with just the FI';

        $sections->{financial_information} = 1;
        $sections->{trading_experience}    = 1;
        $client->broker('MF');
        ok BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 'maltainvest is complete with both FI and TE';

        $sections->{financial_information} = 1;
        $sections->{trading_experience}    = 1;
        $client->broker('CR');

        ok BOM::TradingPlatform::Helper::HelperDerivEZ::_is_financial_assessment_complete($args->%*), 'svg is complete with just FI';

        $mock_cli->unmock_all;
        $mock_fa->unmock_all;
    };
};

done_testing();
