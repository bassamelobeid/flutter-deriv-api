use strict;
use warnings;
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client );
use Test::Fatal;
use Test::MockModule;
use Date::Utility;
use Test::Deep;

subtest 'Adding new comment' => sub {
    my $client = create_client_with_user();

    my $res = $client->add_comment(
        comment => 'Test comment',
        author  => 'test'
    );
    ok $res, 'Comment is added';

    my $err1 = exception { $client->add_comment(author => 'test') };
    is $err1, "CommentRequired\n", "Correct error code for missed comment";

    my $err2 = exception { $client->add_comment(comment => 'Test comment') };
    is $err2, "AuthorRequired\n", "Correct error code for missed author";
};

subtest 'Get comments' => sub {
    my $client = create_client_with_user();

    my $res1 = $client->get_comments();
    is scalar($res1->@*), 0, "No comments yet";

    my $comment_id = $client->add_comment(
        comment => 'Test comment',
        author  => 'test'
    );
    ok $comment_id, 'Comment is added';

    my $res2 = $client->get_comments();
    is scalar($res2->@*),   1,              "Get one added comment";
    is $res2->[0]{id},      $comment_id,    'Comment id is correct';
    is $res2->[0]{comment}, 'Test comment', 'Comment text is correct';
    is $res2->[0]{author},  'test',         'Comment author is correct';

    $client->add_comment(
        comment => 'Test comment1',
        author  => 'test'
    );

    my $res3 = $client->get_comments();
    is scalar($res3->@*), 2, "Get two added comment";
};

subtest 'Delete comment' => sub {
    my $client = create_client_with_user();

    my $comment_id = $client->add_comment(
        comment => 'Test comment',
        author  => 'test'
    );
    ok $comment_id, 'Comment is added';

    my $res1 = $client->get_comments();
    is scalar($res1->@*), 1, "Get one added comment";

    $client->delete_comment(@{$res1->[0]}{qw(id checksum)});

    my $res2 = $client->get_comments();
    is scalar($res2->@*), 0, "Comment is deleted";
};

subtest 'Update comment' => sub {
    my $client = create_client_with_user();

    my $comment_id = $client->add_comment(
        comment => 'Test comment',
        author  => 'test'
    );
    ok $comment_id, 'Comment is added';

    my $res1 = $client->get_comments();
    is scalar($res1->@*), 1, "Get one added comment";

    $client->update_comment(
        id       => $res1->[0]{id},
        comment  => 'Updated test comment',
        author   => 'new_author',
        checksum => $res1->[0]{checksum},
    );

    my $res2 = $client->get_comments();
    is scalar($res2->@*), 1, "Comment still exists";

    is $res2->[0]{comment}, 'Updated test comment', 'Comment is updated';
    is $res2->[0]{author},  'new_author',           'Author is updated';
};

subtest 'Fetch comments from all siblings' => sub {
    my $client = create_client_with_user_and_siblings('CR', 'CR', 'CR', 'MX', 'MF', 'MLT', 'VRTC');
    my $total  = 0;

    my $timestamp  = time;
    my $timestamps = +{map { ($_ => ++$timestamp) } sort { $a cmp $b } $client->user->loginids};

    my $db_hits     = 0;
    my $client_mock = Test::MockModule->new(ref($client));
    $client_mock->mock(
        'set_db',
        sub {
            $db_hits++ if $_[1] eq 'replica';

            return $client_mock->original('set_db')->(@_);
        });

    $client_mock->mock(
        'get_comments',
        sub {
            return [map { +{$_->%*, creation_time => $timestamps->{$_->{client_loginid}},} } $client_mock->original('get_comments')->(@_)->@*];
        });

    for my $loginid ($client->user->loginids) {
        my $sibling = BOM::User::Client->new({loginid => $loginid});

        my $id = $sibling->add_comment(
            comment => "Testing comment for $loginid",
            author  => 'test'
        );

        $total++;
    }

    my $expected = [reverse sort { $a cmp $b } $client->user->loginids];
    my $comments = [map { $_->{client_loginid} } $client->get_all_comments()->@*];

    is scalar @$comments, $total, 'Expected number of comments';
    is $db_hits,          5,      'Only 5 DB hits (same broker code siblings shared the db hit)';
    cmp_deeply $comments, $expected, 'Got the expected order';

    $client_mock->unmock_all;

    subtest 'fiter out dxtrade and mt5 accounts' => sub {
        my $client    = create_client_with_user();
        my $user_mock = Test::MockModule->new(ref($client->user));
        $user_mock->mock(
            'loginids',
            sub {
                return ($client->loginid, 'DXR10000', 'DXD100001', 'MTR10002', 'MTD10003');
            });

        is exception { $client->get_all_comments(); }, undef, 'derivx and mt5 accounts are ignored';

        $user_mock->unmock_all;
    };
};

sub create_client_with_user_and_siblings {
    my $client = create_client(shift);

    my $user = BOM::User->create(
        email    => $client->loginid . '@binary.com',
        password => 'Abcd1234'
    );

    $user->add_client($client);

    for my $broker_code (@_) {
        my $sibling = create_client($broker_code);

        if ($sibling->broker_code eq $client->broker_code) {
            $sibling->binary_user_id($client->binary_user_id);
            $sibling->save();
        }

        $user->add_client($sibling);
    }

    return $client;
}

sub create_client_with_user {
    my $client = create_client();

    my $user = BOM::User->create(
        email    => $client->loginid . '@binary.com',
        password => 'Abcd1234'
    );

    $user->add_client($client);

    return $client;
}

done_testing();
