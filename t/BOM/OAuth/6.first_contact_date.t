use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Date::Utility;
use BOM::Database::Model::OAuth;

my $t      = Test::Mojo->new('BOM::OAuth');
my $app_id = do {
    my $oauth = BOM::Database::Model::OAuth->new;
    $oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
    $oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
    $oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='Test App'");
    my $app = $oauth->create_app({
        name         => 'Test App',
        user_id      => 1,
        scopes       => ['read', 'trade', 'admin'],
        redirect_uri => 'https://www.example.com/'
    });
    $app->{app_id};
};

my $tests = [{
        date       => Date::Utility->new->_minus_months(1)->date_yyyymmdd,
        test       => 'Date in the past should be stored in session',
        in_session => 1,
    },
    {
        date       => Date::Utility->new->_plus_months(1)->date_yyyymmdd,
        test       => 'Date in the future should not be stored in session',
        in_session => 0,
    },
    {
        date       => undef,
        test       => 'Non existent date should not be sstored in session',
        in_session => 0,
    },
    {
        date       => Date::Utility->new->date_yyyymmdd,
        test       => 'Todays date should be stored in session',
        in_session => 1,
    },
    {
        date       => 'I am a garbage date',
        test       => 'Garbage date should not hit the session',
        in_session => 0,
    },
];

my $omock   = Test::MockModule->new('BOM::OAuth::O');
my $session = {};

$omock->mock(
    'session',
    sub {
        my (undef, @args) = @_;

        $session = {$session->%*, @args} if scalar @args == 2;

        return $omock->original('session')->(@_);
    });

for ($tests->@*) {
    my ($date, $test, $in_session) = @{$_}{qw/date test in_session/};

    subtest 'First contact date is ' . ($date // 'not given') => sub {
        $session = {};
        my $url = "/authorize?app_id=$app_id";
        $url = $url . "&date_first_contact=$date" if $date;
        $t   = $t->get_ok($url)->content_like(qr/login/);

        is $session->{date_first_contact}, $date, $test if $in_session;
        ok !$session->{date_first_contact}, $test unless $in_session;
    };
}

done_testing()
