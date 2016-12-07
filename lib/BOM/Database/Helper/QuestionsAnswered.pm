package BOM::Database::Helper::QuestionsAnswered;

use Moose;
use Rose::DB;
use Carp;

has 'login_id' => (
    is => 'rw',
);

has 'qid' => (
    is => 'rw',
);

has 'pass' => (
    is => 'rw',
);

has 'test_id' => (
    is => 'rw',
);

has 'db' => (
    is  => 'rw',
    isa => 'Rose::DB',
);

sub record_questions_answered {
    my $self = shift;

    $self->db->dbh->do('INSERT INTO questions_answered (loginid,qid,pass,test_id) values(?,?,?,?)',
        undef, $self->login_id, $self->qid, $self->pass, $self->test_id);

    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
