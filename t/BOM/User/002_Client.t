use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Client;

my $login_id = 'CR0009';

subtest 'Almost all accessor/modifiers' => sub {
    plan tests => 17;

    my $client = BOM::User::Client::get_instance({'loginid' => $login_id});
    note "broker_code ", $client->broker_code;
    note "broker ",      $client->broker;

    is($client->fully_authenticated(), 1, 'The client is fully authenticated');

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

    $client->phone('00869145685791');

    is($client->phone, '00869145685791', "Got the client telephone number");

    $client->set_exclusion->max_open_bets(50);

    is($client->self_exclusion->max_open_bets, 50, "the client maximum open positions number is 50 as it's changed.");

    $client->set_exclusion->max_turnover(1000);

    is($client->self_exclusion->max_turnover, 1000, "the client maximum daily turnover number is 1000 as it's changed.");

    $client->set_exclusion->max_losses(1001);

    is($client->self_exclusion->max_losses, 1001, "the client maximum daily losses number is 1001 as it's changed.");

    $client->set_exclusion->max_7day_turnover(1002);

    is($client->self_exclusion->max_7day_turnover, 1002, "the client maximum 7-day turnover number is 1002 as it's changed.");

    $client->set_exclusion->max_7day_losses(1003);

    is($client->self_exclusion->max_7day_losses, 1003, "the client maximum 7-day losses number is 1003 as it's changed.");

    $client->set_exclusion->max_balance(200000);

    is($client->self_exclusion->max_balance, 200000, "the client maximum acbal number is 200000 as it is changed.");

    $client->set_exclusion->exclude_until('2009-09-06');

    is($client->self_exclusion->exclude_until, '2009-09-06T00:00:00', "the client limit exclude until number is 2009-09-06.");

    my $timeout_until = time() + 86400;
    $client->set_exclusion->timeout_until($timeout_until);

    is($client->self_exclusion->timeout_until, $timeout_until, "the client limit timeout until number is right.");

    $client->set_exclusion->session_duration_limit(20);

    is($client->self_exclusion->session_duration_limit, 20, "the client session duration is 20 minutes.");

    $client->save();

    my $return;

    $client->status->set('disabled', 'fuguo wei', "I don't like him");

    $return = $client->status->disabled;
    is($return && $return->{reason}, "I don't like him", "the client is disabled and the reason is: I don not like him");
    is($return->{staff_name}, 'fuguo wei', "The disabled operation clerk is fuguo wei");

    $client->status->set('disabled', 'fuguo wei', "He is hacker");

    $return = $client->status->disabled;
    is($return->{reason},     'He is hacker', "the client is disabled update the reason to: He is hacker");
    is($return->{staff_name}, 'fuguo wei',    "The disabled operation clerk is fuguo wei");

    $client->status->clear_disabled;
    is($client->status->disabled, undef, "the client is enabled");

};

