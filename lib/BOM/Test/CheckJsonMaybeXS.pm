package BOM::Test::CheckJsonMaybeXS;

=head1 NAME

BOM::Test::CheckJsonMaybeXS - The test to check if L<JSON::MaybeXS> return a L<Cpanel::JSON::XS> object when we load our modules.

=head1 DESCRIPTION

We use L<JSON::MaybeXS> to handle json because it has a better interface. But it will return object with different class if we load L<JSON::XS> or L<Cpanel::JSON::XS>
before it. Please see L<the source code|https://metacpan.org/release/JSON-MaybeXS/source/lib/JSON/MaybeXS.pm#L11> of L<JSON::MaybeXS>.

We need to make sure in our code L<JSON::MaybeXS> will always return L<Cpanel::JSON::XS> at any time.

=cut

use strict;
use warnings;
use Exporter 'import';
use Test::More;
use IO::Pipe;
use Storable qw(freeze thaw);
use Path::Tiny;
use List::MoreUtils qw(any);
use Syntax::Keyword::Try;

our @EXPORT_OK = qw(check_JSON_MaybeXS);

=head1 Functions

=head2 check_JSON_MaybeXS

Check if L<JSON::MaybeXS> return L<Cpanel::JSON::XS> object after load modules in directory 'lib' one by one.

Parameters:

=over

=item * skip_files - The files that need to be skipped.

=back

Return: undef

=cut

sub check_JSON_MaybeXS {
    my %args = @_;
    $args{skip_files} //= [];
    BAIL_OUT("This test should be run under the root directory of the current repositories.") unless path('./.git')->exists;

    for my $file (get_test_files()) {
        if (any { $file eq $_ } $args{skip_files}->@*) {
            diag("file $file is skipped");
            next;
        }
        file_ok($file);
    }
    return;
}

=head2 file_ok

Fork a subprocess and load module and check L<JSON::MaybeXS> result.

Parameters:

=over

=item * file - The module file that will be used

=back

return : undef

=cut

sub file_ok {
    my ($file) = @_;
    my $pipe   = IO::Pipe->new;
    my $pid    = fork();

    die "fork failed $!" unless defined $pid;

    if ($pid != 0) {    # self
        $pipe->reader;
        my $results = thaw(join('', <$pipe>));
        return _results_as_tests($file, $?, $results);
    } else {            # child
        $pipe->writer;
        exit !_check_object_for_cpanel_json_xs_usage($file, $pipe);
    }

    return;
}

=head2 _check_object_for_cpanel_json_xs_usage

require a module and create a L<JSON::MaybeXS> and check the result is a L<Cpanel::JSON::XS>

Parameters:

=over

=item * file - The checked module file

=item * pipe - L<IO::Pipe> object used to send result to parent process

=back

return: 1

=cut

sub _check_object_for_cpanel_json_xs_usage {
    my ($file, $pipe) = @_;

    my $orig_file = $file;

    my @results;
    local @INC = @INC;
    if ($file =~ s{\A (.*\b lib)/}{}xms) {
        unshift @INC, $1;
    }
    try {
        require $file;
    } catch {
        $@ =~ s/\n .*//xms;
        push @results, [diag => "Testing JSON::MaybeXS ignores $orig_file because: $@"];
        _pipe_results($pipe, @results);
        return 1;
    }

    require JSON::MaybeXS;
    my $json         = JSON::MaybeXS->new;
    my @json_results = ['pass', "JSON::MaybeXS->new returned Cpanel::JSON::XS in file $file."];
    if (not $json->isa('Cpanel::JSON::XS')) {
        my $class = ref($json);
        $json_results[0][0] = 'fail';
        push @json_results,
            [
            'diag',
            "JSON::MaybeXS returned $class. Please check the code to replace $class with JSON::MaybeXS, or put $class after JSON::MaybeXS to avoid this problem."
            ];
    }
    push @results, @json_results;
    _pipe_results($pipe, @results);
    return 1;
}

=head2 _pipe_result

Freeze and write messages into pipe, then close pipe

Parameters:

=over

=item * $pipe - L<IO::Pipe> object used to talk with parent process

=item * @messages - messages sent to parent proces

=back

return: undef

=cut

sub _pipe_results {
    my ($pipe, @messages) = @_;
    print $pipe freeze(\@messages);
    close $pipe;
    return;
}

=head2 _results_as_tests

Process results and represent them with Test::More methods

Parameters:

=over

=item * $file - The module file

=item * $exit_code - The exit code of subprocess

=item * $results - The results generated in subprocess

=back

Return: undef

=cut

sub _results_as_tests {
    my ($file, $exit_code, $results) = @_;
    is($exit_code, 0, "file $file compiled successfully");
    no strict "refs";
    for my $result ($results->@*) {
        my ($method, $message) = @$result;
        $method->($message);
    }
    return;
}

=head2 get_test_files

get module files under directory lib

Parameters: none

Return: module files

=cut

sub get_test_files {
    my @files = qx{find lib -type f};
    chomp @files;
    return @files;
}

1;
