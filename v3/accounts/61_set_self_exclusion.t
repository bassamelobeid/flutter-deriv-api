use strict;
use warnings;
use Test::More;
use Date::Utility;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::User::Client;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;

use await;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_wsapi_test();

my $email       = 'test-binary' . rand(999) . '@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
});
$test_client->email($email);
$test_client->save;
$test_client->set_default_account('USD');

my $loginid = $test_client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($test_client);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

# authorize ok
$t->await::authorize({authorize => $token});

# get_self_exclusion
my $res = $t->await::get_self_exclusion({get_self_exclusion => 1});
ok($res->{get_self_exclusion});
test_schema('get_self_exclusion', $res);
is_deeply $res->{get_self_exclusion}, {}, 'all are blank';

# Error test for open positions
$res = $t->await::set_self_exclusion({
    set_self_exclusion => 1,
    max_balance        => 10000,
    max_open_bets      => 120,      # limit is 100 so this should be over
    max_turnover       => undef,    # null should be OK to pass
    max_7day_losses    => 0,        # 0 is ok to pass but not saved
});

is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'max_open_bets';
my $max = $test_client->get_limit_for_open_positions;
ok $res->{error}->{message} =~ /Please enter a number between 1 and $max/;

# Error test for maximum balance
$res = $t->await::set_self_exclusion({
    set_self_exclusion => 1,
    max_balance        => 1000000,
    max_open_bets      => 50,
    max_turnover       => undef,     # null should be OK to pass
    max_7day_losses    => 0,         # 0 is ok to pass but not saved
});

is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'max_balance';
$max = $test_client->get_limit_for_account_balance;
ok $res->{error}->{message} =~ /Please enter a number between 0 and $max/;

# Set self-exclusion
$res = $t->await::set_self_exclusion({
    set_self_exclusion => 1,
    max_balance        => 10000,
    max_open_bets      => 50,
    max_turnover       => undef,    # null should be OK to pass
    max_7day_losses    => 0,        # 0 is ok to pass but not saved
});

ok($res->{set_self_exclusion});
test_schema('set_self_exclusion', $res);

# re-get should be get what saved
$res = $t->await::get_self_exclusion({get_self_exclusion => 1});
ok($res->{get_self_exclusion});
test_schema('get_self_exclusion', $res);
my %data = %{$res->{get_self_exclusion}};
is $data{max_balance},     10000, 'max_balance saved ok';
is $data{max_turnover},    undef, 'max_turnover is not there';
is $data{max_7day_losses}, undef, 'max_7day_losses is not saved';
is $data{max_open_bets},   50,    'max_open_bets saved';

$res = $t->await::set_self_exclusion({
    set_self_exclusion => 1,
    max_balance        => 9999,
    max_turnover       => 1000,
});

# can set single field
ok($res->{set_self_exclusion});
test_schema('set_self_exclusion', $res);

$res = $t->await::set_self_exclusion({
    set_self_exclusion => 1,
    max_balance        => 9999,
    max_turnover       => 1000,
    max_open_bets      => 0,      # 0 is not ok if it was set
});
is $res->{error}->{code}, 'SetSelfExclusionError';
is $res->{error}->{field}, 'max_open_bets', 'max open bets was set so it can not be set to 0';
test_schema('set_self_exclusion', $res);

$res = $t->await::set_self_exclusion({
    set_self_exclusion => 1,
    max_balance        => 9999,
    max_turnover       => 1000,
    max_open_bets      => 50,
});
ok($res->{set_self_exclusion});
test_schema('set_self_exclusion', $res);

# re-get should be get what saved
$res = $t->await::get_self_exclusion({get_self_exclusion => 1});
ok($res->{get_self_exclusion});
test_schema('get_self_exclusion', $res);
%data = %{$res->{get_self_exclusion}};
is $data{max_balance},   9999, 'max_balance is updated';
is $data{max_turnover},  1000, 'max_turnover is saved';
is $data{max_open_bets}, 50,   'max_open_bets is untouched';

## do some validation
$res = $t->await::set_self_exclusion({
    set_self_exclusion => 1,
    max_balance        => 10001,
    max_turnover       => 1000,
    max_open_bets      => 50,
});
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'max_balance';
test_schema('set_self_exclusion', $res);

$res = $t->await::set_self_exclusion({
    set_self_exclusion     => 1,
    max_balance            => 9999,
    max_turnover           => 1000,
    max_open_bets          => 50,
    session_duration_limit => 1440 * 42 + 1,
});
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'session_duration_limit';
ok $res->{error}->{message} =~ /more than 6 weeks/;

$res = $t->await::set_self_exclusion({
    set_self_exclusion     => 1,
    max_balance            => 9999,
    max_turnover           => 1000,
    max_open_bets          => 50,
    session_duration_limit => 1440,
    exclude_until          => '2010-01-01'
});
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'exclude_until';
ok $res->{error}->{message} =~ /after today/;

$res = $t->await::set_self_exclusion({
    set_self_exclusion     => 1,
    max_balance            => 9999,
    max_turnover           => 1000,
    max_open_bets          => 50,
    session_duration_limit => 1440,
    exclude_until          => Date::Utility->new->plus_time_interval('3mo')->date_yyyymmdd,
});
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'exclude_until';
ok $res->{error}->{message} =~ /less than 6 months/;

$res = $t->await::set_self_exclusion({
    set_self_exclusion     => 1,
    max_balance            => 9999,
    max_turnover           => 1000,
    max_open_bets          => 50,
    session_duration_limit => 1440,
    exclude_until          => Date::Utility->new->plus_time_interval('6y')->date_yyyymmdd,
});
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'exclude_until';
ok $res->{error}->{message} =~ /more than five years/;

## timeout_until
$res = $t->await::set_self_exclusion({
    set_self_exclusion     => 1,
    max_balance            => 9999,
    max_turnover           => 1000,
    max_open_bets          => 50,
    session_duration_limit => 1440,
    timeout_until          => time() - 86400,
});
is $res->{error}->{code},  'SetSelfExclusionError';
is $res->{error}->{field}, 'timeout_until';
ok $res->{error}->{message} =~ /greater than current time/;

# good one
my $exclude_until = Date::Utility->new->plus_time_interval("7mo")->date_yyyymmdd;
my $timeout_until = Date::Utility->new->plus_time_interval("2d");
$res = $t->await::set_self_exclusion({
    set_self_exclusion     => 1,
    max_balance            => 9998,
    max_turnover           => 1000,
    max_open_bets          => 50,
    session_duration_limit => 1440,
    exclude_until          => $exclude_until,
    timeout_until          => $timeout_until->epoch,
});
ok($res->{set_self_exclusion});
test_schema('set_self_exclusion', $res);

# re-set should throw an error
$res = $t->await::set_self_exclusion({
    set_self_exclusion     => 1,
    max_balance            => 9998,
    max_turnover           => 1000,
    max_open_bets          => 50,
    session_duration_limit => 1440,
    exclude_until          => $exclude_until,
    timeout_until          => $timeout_until->epoch,
});
ok($res->{error});
is $res->{error}->{code}, 'SelfExclusion',
    "Self-excluded clients are not allowed to change their self-exclusion settings. Error message will be shown upon self-excluded client's attempt to change self-exclusion settings.";

$res = $t->await::get_self_exclusion({get_self_exclusion => 1});
ok $res->{get_self_exclusion};
test_schema('get_self_exclusion', $res);

## try read from db
my $client    = BOM::User::Client->new({loginid => $test_client->loginid});
my $self_excl = $client->get_self_exclusion;
is $self_excl->max_balance, 9998, 'set correct in db';
is $self_excl->exclude_until, $exclude_until . 'T00:00:00', 'exclude_until in db is right';
is $self_excl->timeout_until, $timeout_until->epoch, 'timeout_until is right';
is $self_excl->session_duration_limit, 1440, 'all good';

$t->finish_ok;

done_testing();
