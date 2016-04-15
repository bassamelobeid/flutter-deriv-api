use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Client;

my $login_id = 'CR0009';

subtest 'Almost all accessor/modifiers' => sub {
    plan tests => 39;

    my $client;
    lives_ok { $client = BOM::Platform::Client::get_instance({'loginid' => $login_id}); }
    "Can create client object 'BOM::Platform::Client::get_instance({'loginid' => $login_id})'";
    note "broker_code ", $client->broker_code;
    note "broker ",      $client->broker;

    is($client->client_fully_authenticated(), 1, 'The client is fully authenticated');

    is(
        $client->get_limit({
                for      => 'account_balance',
                currency => 'USD'
            }
        ),
        200000,
        'The client limit has been retrieved'
    );

    my $error_expected = 'CR0009.certified_passport.png';

    Test::Exception::lives_ok { $client->phone('00869145685791'); } "Can set the telephone number as 00869145685791";

    is($client->phone, '00869145685791', "Got the client telephone number");

    Test::Exception::lives_ok { $client->cashier_setting_password('ILOVEBUGS'); } "Can set the cashier_setting_password as [ILOVEBUGS]";

    is($client->cashier_setting_password, 'ILOVEBUGS', "Got the client cashier_setting_password");

    Test::Exception::lives_ok { $client->set_exclusion->max_open_bets(50) } "can set the maxopenpositions_limit client attribute";

    is($client->self_exclusion->max_open_bets, 50, "the client maximum open positions number is 50 as it's changed.");

    Test::Exception::lives_ok { $client->set_exclusion->max_turnover(1000) } "can set the maxopenorders_limit client attribute";

    is($client->self_exclusion->max_turnover, 1000, "the client maximum daily turnover number is 1000 as it's changed.");

    Test::Exception::lives_ok { $client->set_exclusion->max_losses(1001) } "can set the max_losses client attribute";

    is($client->self_exclusion->max_losses, 1001, "the client maximum daily losses number is 1001 as it's changed.");

    Test::Exception::lives_ok { $client->set_exclusion->max_7day_turnover(1002) } "can set the max_7day_turnover client attribute";

    is($client->self_exclusion->max_7day_turnover, 1002, "the client maximum 7-day turnover number is 1002 as it's changed.");

    Test::Exception::lives_ok { $client->set_exclusion->max_7day_losses(1003) } "can set the max_7day_losses client attribute";

    is($client->self_exclusion->max_7day_losses, 1003, "the client maximum 7-day losses number is 1003 as it's changed.");

    Test::Exception::lives_ok { $client->set_exclusion->max_balance(200000) } "can set the maxacbal_limit client attribute";

    is($client->self_exclusion->max_balance, 200000, "the client maximum acbal number is 200000 as it is changed.");

    Test::Exception::lives_ok { $client->set_exclusion->exclude_until('2009-09-06') } "can set the maxopenorders_limit client attribute";

    is($client->self_exclusion->exclude_until, '2009-09-06T00:00:00', "the client limit exclude until number is 2009-09-06.");

    Test::Exception::lives_ok { $client->set_exclusion->session_duration_limit(20) } "can set the client session duration attribute";

    is($client->self_exclusion->session_duration_limit, 20, "the client session duration is 20 minutes.");

    Test::Exception::lives_ok { $client->save() } "Can save all the limit changes back to the client";

    my $return;

    Test::Exception::lives_ok {
        $client->set_status('disabled', 'fuguo wei', "I don't like him");
    }
    "can set the disable client attribute";

    Test::Exception::lives_ok { $client->save } "Can save the disabled changes back to client";

    $return = $client->get_status('disabled');
    is($return && $return->reason, "I don't like him", "the client is disabled and the reason is: I don not like him");
    is($return->staff_name, 'fuguo wei', "The disabled operation clerk is fuguo wei");

    Test::Exception::lives_ok {
        $client->set_status('disabled', 'fuguo wei', 'He is hacker');
    }
    "can set the disable client attribute";

    Test::Exception::lives_ok { $client->save } "Can update the disabled reason";

    $return = $client->get_status('disabled');
    is($return->reason,     'He is hacker', "the client is disabled update the reason to: He is hacker");
    is($return->staff_name, 'fuguo wei',    "The disabled operation clerk is fuguo wei");

    Test::Exception::lives_ok { $client->clr_status('disabled') } "can set the enable client attribute";
    Test::Exception::lives_ok { $client->save } "Can save the disabled changes back to client";
    is($client->get_status('disabled'), undef, "the client is enabled");

    is($client->payment_agent_withdrawal_expiration_date, undef, "payment_agent_withdrawal_expiration_date is undef");
    Test::Exception::lives_ok {
        $client->payment_agent_withdrawal_expiration_date('2013-01-01');
    }
    "can set payment agent withdrawal expiration date";
    Test::Exception::lives_ok { $client->save } "Can update payment agent withdrawal expiration date";
    ok($client->payment_agent_withdrawal_expiration_date =~ /^2013-01-01/, "payment_agent_withdrawal_expiration_date matches");
};

