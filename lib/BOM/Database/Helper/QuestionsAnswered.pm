package BOM::Database::Helper::QuestionsAnswered;

use Moose;
use Rose::DB;
use Carp;

has 'login_id' => (
    is => 'ro',
);

has 'test_id' => (
    is => 'ro',
);

has questions => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
);

has 'db' => (
    is  => 'ro',
    isa => 'Rose::DB',
);

sub record_questions_answered {
    my $self = shift;

    my $dbic = $self->db->dbic;

    $dbic->txn(
        sub {
            my $insert_sth = $_->prepare(
                q{
        INSERT INTO japan.questions_answered (client_loginid, qid, answer, pass,test_id, question_presented, category) values(?,?,?,?,?,?,?)
    }
            );

            for my $question (@{$self->questions}) {
                $insert_sth->execute($self->login_id, $question->{id}, $question->{answer}, $question->{pass}, $self->test_id, $question->{question},
                    $question->{category});

            }
        });
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
