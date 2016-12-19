package BOM::Database::Helper::QuestionsAnswered;

use Moose;
use Rose::DB;
use Carp;

has 'login_id' => (
    is => 'rw',
);

has 'test_id' => (
    is => 'rw',
);

has questions => (
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub { [] },
);

has 'db' => (
    is  => 'rw',
    isa => 'Rose::DB',
);

sub record_questions_answered {
    my $self = shift;

    $self->db->dbh->{AutoCommit} = 0;

    my $insert_sth = $self->db->dbh->prepare(
        q{
        INSERT INTO japan.questions_answered (client_loginid, qid, answer, pass,test_id, question_presented, category) values(?,?,?,?,?,?,?)
    }
    );

    for my $question (@{$self->questions}) {
        $insert_sth->execute($self->login_id, $question->{id}, $question->{answer}, $question->{pass}, $self->test_id, $question->{question},
            $question->{category});

    }

    $self->db->dbh->commit;

    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
