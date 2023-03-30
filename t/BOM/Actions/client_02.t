use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);

use BOM::Event::Actions::Client;
use BOM::User;
use Date::Utility;

subtest 'POA updated' => sub {

    sub grab_issuance_date {
        my ($user) = @_;

        return $user->dbic->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM users.poa_issuance WHERE binary_user_id = ?', {Slice => {}}, $user->id);
            });
    }

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email          => 'error+test@test.com',
        password       => "hello",
        email_verified => 1,
        email_consent  => 1,
    );

    $user->add_client($client);
    $client->binary_user_id($user->id);
    $client->save;

    my $doc_mock = Test::MockModule->new(ref($client->documents));
    my $best_issue_date;
    $doc_mock->mock(
        'best_issue_date',
        sub {
            return Date::Utility->new($best_issue_date) if $best_issue_date;
            return undef;
        });

    my $exception = exception {
        BOM::Event::Actions::Client::poa_updated({
                loginid => undef,
            })->get;
    };

    ok $exception =~ /No client login ID supplied/, 'Expected exception if no loginid is supplied';

    $exception = exception {
        BOM::Event::Actions::Client::poa_updated({
                loginid => 'CR0',
            })->get;
    };

    ok $exception =~ /Could not instantiate client for login ID/, 'Expected exception when bogus loginid is supplied';

    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_issuance_date($user), [], 'Undef date would be a delete operation';

    $best_issue_date = '2020-10-10';
    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_issuance_date($user),
        [{
            binary_user_id => $user->id,
            issue_date     => Date::Utility->new($best_issue_date)->date_yyyymmdd,
        }
        ],
        'Insert operation';

    $best_issue_date = '2023-10-10';
    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_issuance_date($user),
        [{
            binary_user_id => $user->id,
            issue_date     => Date::Utility->new($best_issue_date)->date_yyyymmdd,
        }
        ],
        'Update operation';

    $best_issue_date = undef;
    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_issuance_date($user), [], 'Delete operation';
};

done_testing();
