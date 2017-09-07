package BOM::Test::Suite::DSL;
use strict;
use warnings;

use Test::Most;
use BOM::Test::Suite;

use Exporter 'import';
our @EXPORT = qw(
    start
    set_language
    test_sendrecv
    fail_test_sendrecv
    finish
);

my $suite;

sub start {
    my %args = @_;

    $suite = BOM::Test::Suite->new(%args);
}

sub set_language {
    my ($language) = @_;
    $suite->set_language($language);
}

sub test_sendrecv {
    my ($send_file, $receive_file, %args) = @_;
    $suite->exec_test(
        send_file     => $send_file,
        receive_file  => $receive_file,
        linenum       => (caller)[2],
        %args,
    );
}
sub fail_test_sendrecv {
    my ($send_file, $receive_file, %args) = @_;
    test_sendrecv($send_file, $receive_file, %args,
        expect_fail   => 1,
        linenum       => (caller)[2],
    );
}

sub finish {
    $suite->finish;
    done_testing();
}

1;
