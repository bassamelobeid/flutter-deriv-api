package BOM::Test::LocalizeSyntax;

use strict;
use warnings;

use Locale::Maketext::Extract;
use Test::Most;
use Path::Tiny;
use Term::ANSIColor qw(colored);
use base            qw( Exporter );
our @EXPORT_OK = qw(check_localize_string_structure);

=head1 Name

BOM::Test::LocalizeSyntax - a module to test localize string format.

=cut

=head1 Functions

=head2 _get_local_extract

return Locale::Maketext::Extract object

=cut

sub _get_locale_extract {
    return Locale::Maketext::Extract->new(

        # Specify which parser plugins to use
        plugins => {

            # Use Perl parser, process files with extension .pl .pm .cgi
            perl => ['pm'],

            # Use TT2 parser, process files with extension .tt2 .tt .html
            # or which match the regex
            tt2     => ['tt2', 'tt', 'html'],
            generic => ["html.ep"],
        },

        # Warn if a parser can't process a file or problems loading a plugin
        warnings => 1,

        # List processed files
        verbose => 1,
    );
}

=head2 _log_fail

pretty print test failure message

=cut

sub _log_fail {
    my ($message, $source_string, $entry) = @_;

    fail $message;
    note colored('  ==> String: ', 'bold'), colored("\"$source_string\"", 'bright_red');
    for (@$entry) {
        my ($path, $line) = @$_;
        note colored('  --> Location: ', 'bold'), colored($path, 'underline');
        my @lines = $path->lines;
        note colored("\t$line | " . $lines[$line - 1], 'bright_black');
    }
}

=head2 _validate_string

validate localize string

=cut

sub _validate_string {
    my ($source_string, $entry) = @_;
    my $is_ok = 1;

    if ($source_string =~ /^\s|\$/) {
        $is_ok = 0;
        _log_fail('Should not start with space nor should have any direct variable.', $source_string, $entry);
    }

    # We can only check for underscore as of now
    if ($source_string =~ /_/) {
        $is_ok = 0;
        _log_fail('Should not contain field names. Please use placeholder instead.', $source_string, $entry);
    }
    return $is_ok;
}

=head2 do_test

do test and returt test result

return: compiled localize entries and passed count

=cut

sub do_test {
    my @changed_files = @_;

    my $Ext = _get_locale_extract();
    @changed_files = grep { /\.(pm|cgi)$/ } map { chomp; $_ } @changed_files;
    foreach my $file (@changed_files) {
        next unless path($file)->exists;
        diag("processing $file");
        $Ext->extract_file(path($file)->realpath);
    }
    $Ext->compile();

    my $passed_count = 0;

    my $entries = $Ext->compiled_entries();
    foreach my $string_to_translate (sort keys %{$entries}) {
        $passed_count++
            if (_validate_string($string_to_translate, $entries->{$string_to_translate}));
    }

    return $entries, $passed_count;
}

=head2 check_localize_string_strucutre

Entrance function to test localize string structure

Argument: file list that need to test

=cut

sub check_localize_string_structure {
    my @changed_files = @_;
    subtest 'validate localize string structure' => sub {
        my ($entries, $passed_count) = do_test(@changed_files);
        unless (keys %{$entries}) {
            ok(1, colored("No string to check", 'yellow'));
        } elsif ($passed_count > 0) {
            ok(1, colored("$passed_count strings found to be OK", 'green'));
        }
    };
}

1;
