package BOM::Test::Suite::DSL;
use strict;
use warnings;

use Test::Most;
use BOM::Test::Suite;

use Exporter 'import';
our @EXPORT =    ## no critic (ProhibitAutomaticExportation)
    qw(
    start
    reset_app
    set_language
    test_sendrecv
    test_sendrecv_params
    fail_test_sendrecv
    fail_test_sendrecv_params
    test_last_stream
    test_last_stream_params
    finish
);

my $suite;

sub start {
    my %args = @_;

    $suite = BOM::Test::Suite->new(%args);
    return $suite;
}

sub reset_app {
    $suite->reset_app;
    return;
}

sub set_language {
    my ($language) = @_;
    $suite->set_language($language);
    return;
}

sub test_sendrecv {
    my ($send_file, $receive_file, %args) = @_;
    $suite->exec_test(
        send_file    => $send_file,
        receive_file => $receive_file,
        linenum      => (caller)[2],
        %args,
    );
    return;
}

sub test_sendrecv_params {
    my ($send_file, $recv_file, @params) = @_;
    test_sendrecv(
        $send_file, $recv_file,
        template_values => \@params,
        linenum         => (caller)[2],
    );
    return;
}

sub fail_test_sendrecv {
    my ($send_file, $receive_file, %args) = @_;
    test_sendrecv(
        $send_file, $receive_file,
        expect_fail => 1,
        linenum     => (caller)[2],
        %args,
    );
    return;
}

sub fail_test_sendrecv_params {
    my ($send_file, $recv_file, @params) = @_;
    test_sendrecv(
        $send_file, $recv_file,
        expect_fail     => 1,
        template_values => \@params,
        linenum         => (caller)[2],
    );
    return;
}

sub test_last_stream {
    my ($stream_id, $recv_file, %args) = @_;
    $suite->exec_test(
        test_stream_id => $stream_id,
        receive_file   => $recv_file,
        linenum        => (caller)[2],
        %args,
    );
    return;
}

sub test_last_stream_params {
    my ($stream_id, $recv_file, @params) = @_;
    test_last_stream(
        $stream_id, $recv_file,
        template_values => \@params,
        linenum         => (caller)[2],
    );
    return;
}

sub finish {
    $suite->finish;
    done_testing();
    return;
}

1;
