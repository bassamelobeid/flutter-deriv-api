use strict;
use warnings;
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use Test::Fatal;

subtest 'Adding new comment' => sub {
    my $client = create_client();

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
    my $client = create_client();

    my $res1 = $client->get_comments();
    is scalar($res1->@*), 0, "No comments yet";

    my $comment_id = $client->add_comment(
        comment => 'Test comment',
        author  => 'test'
    );
    ok $comment_id, 'Comment is added';

    my $res2 = $client->get_comments();
    is scalar($res2->@*), 1, "Get one added comment";
    is $res2->[0]{id}, $comment_id, 'Comment id is correct';
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
    my $client = create_client();

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
    my $client = create_client();

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

done_testing();
