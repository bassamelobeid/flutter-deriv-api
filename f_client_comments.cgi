#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use HTML::Entities;
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType http_redirect );
use JSON::MaybeXS;
use JSON::MaybeUTF8 qw(:v1);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Cookie;
use BOM::User::AuditLog;
use BOM::User::Client;
use Syntax::Keyword::Try;

use constant {
    SALT_FOR_CSRF_TOKEN_COMMENTS => 'emDWVx1SH68JE5N1ba9IGz5fb',
    COMMENT_LIMIT                => 1000,
};

BOM::Backoffice::Sysinit::init();

my %ERROR_MESSAGE = (
    CommentRequired         => 'Comment content could not be empty',
    AuthorRequired          => 'Something went wrong: author field could not be empty. Please report to Backend',
    CommentIDRequired       => 'Something went wrong: id field could not be empty. Please report to Backend',
    ChecksumRequired        => 'Something went wrong: checksum field could not be empty. Please report to Backend',
    CommentNotFound         => 'Requested comment is not found.',
    CommentChecksumMismatch => 'The comment was updated during your operation, Please check it and try again',
    DublicateComment        => 'Comment with this content is already added.',
    CommentTooLong          => 'Comment is too long. Limit is ' . COMMENT_LIMIT . ' symbols',
);

my %action_router = (
    add_comment    => \&add_comment,
    delete_comment => \&delete_comment,
    update_comment => \&update_comment,
    show_edit_form => \&show_edit_form,
);

my $input = request()->params;
PrintContentType();

return_error('Client loginid is missed') unless $input->{loginid};

my $client = eval { BOM::User::Client->new({loginid => $input->{loginid}}) };

return_error('Invalid clientloginid, Client not found') unless $client;

my $result;
my $action = $input->{action} && $action_router{$input->{action}};

my $error_msg = '';
if ($action && request()->http_method eq 'POST') {
    return_error('Invalid CSRF Token') unless ($input->{csrf} // '') eq get_csrf_token();

    try {
        $result = $action->(
            client => $client,
            clerk  => BOM::Backoffice::Auth0::get_staffname(),
            input  => $input,
        );
    }
    catch {
        my $err = $@;
        chomp($err) unless ref $err;

        if ($input->{action} eq 'update_comment') {
            $input->{action} = 'show_edit_form';
            if ($err eq 'CommentChecksumMismatch') {
                my $action = $action_router{$input->{action}};
                $result = $action->(
                    client => $client,
                    clerk  => BOM::Backoffice::Auth0::get_staffname(),
                    input  => $input,
                );
            }
        }

        if ($ERROR_MESSAGE{$err}) {
            $error_msg = $ERROR_MESSAGE{$err};
        } else {
            $error_msg = 'Something went wrong.  ' . $err;
        }
    }
}

BrokerPresentation("Client Review Comments");

BOM::Backoffice::Request::template()->process(
    'backoffice/client_comments.html.tt',
    {
        comments => $client->get_comments(),
        action   => $input->{action} // '',
        input    => $input,
        result   => $result,
        csrf     => get_csrf_token(),
        error    => $error_msg,
    });

code_exit_BO();

sub get_comments {
    my (%args) = @_;

    return $args{client}->get_comments();
}

sub add_comment {
    my (%args) = @_;

    #Clean up comment
    $args{input}{comment} =~ s/\r\n/\n/g;
    $args{input}{comment} =~ s/^\s+|\s+$//g;
    die "CommentTooLong\n" if length $args{input}{comment} > COMMENT_LIMIT;
    try {
        $args{client}->add_comment(
            comment => $args{input}{comment},
            author  => $args{clerk},
            section => 'mlro',                  # by default we'll put mark all comment as MLRO.
        );
    }
    catch {
        my $err = $@;
        die "DublicateComment\n" if $err =~ /Cannot add duplicate comment for table/;

        die $err;
    }

    http_redirect BOM::Backoffice::Request::request()->url_for('backoffice/f_client_comments.cgi', {loginid => $args{client}->loginid});
    return;
}

sub delete_comment {
    my (%args) = @_;

    my $record = _get_comment_by_id($args{client}, $args{input}{id});

    die "CommentNotFound\n" unless $record;

    die "CommentChecksumMismatch\n" unless $record->{checksum} eq $args{input}{checksum};

    $args{client}->delete_comment($args{input}{id}, $args{input}{checksum});

    http_redirect BOM::Backoffice::Request::request()->url_for('backoffice/f_client_comments.cgi', {loginid => $args{client}->loginid});
    return;
}

sub show_edit_form {
    my (%args) = @_;

    die "CommentIDRequired\n" unless $args{input}{id};

    my $record = _get_comment_by_id($args{client}, $args{input}{id});

    die "CommentNotFound\n" unless $record;

    return $record;
}

sub update_comment {
    my (%args) = @_;

    my $record = _get_comment_by_id($args{client}, $args{input}{id});

    die "CommentNotFound\n" unless $record;

    die "CommentChecksumMismatch\n" unless $record->{checksum} eq $args{input}{checksum};

    #Clean up comment
    $args{input}{comment} =~ s/\r\n/\n/g;
    $args{input}{comment} =~ s/^\s+|\s+$//g;
    die "CommentTooLong\n" if length $args{input}{comment} > COMMENT_LIMIT;

    $args{client}->update_comment(
        id       => $args{input}{id},
        comment  => $args{input}{comment},
        author   => $args{clerk},
        checksum => $args{input}{checksum},
    );

    http_redirect BOM::Backoffice::Request::request()->url_for('backoffice/f_client_comments.cgi', {loginid => $args{client}->loginid});
    return;
}

sub _get_comment_by_id {
    my ($client, $id) = @_;

    my ($record) = grep { $_->{id} == $id } $client->get_comments()->@*;

    return $record;
}

sub get_csrf_token {
    my $auth_token = request()->cookies->{auth_token};

    die "Can't find auth token" unless $auth_token;

    return sha256_hex(SALT_FOR_CSRF_TOKEN_COMMENTS . $auth_token);
}

sub return_error {
    my ($error_msg) = @_;

    BrokerPresentation("Client Review Comments");
    code_exit_BO(_get_display_error_message($error_msg));
}
