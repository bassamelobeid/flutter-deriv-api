use strict;
use warnings;

use Locale::Maketext::Extract;
use File::Find::Rule;
use Test::Most;
use Path::Tiny;
use Dir::Self;
use File::Basename;
use Term::ANSIColor qw(colored);

my @repositories_containing_localize = qw(
    binary-websocket-api
    bom
    bom-backoffice
    bom-cryptocurrency
    bom-events
    bom-platform
    bom-pricing
    bom-rpc
    bom-transaction
);

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

sub _log_fail {
    my ($message, $source_string, $entry, $is_ok) = @_;

    fail $message;
    note colored('  ==> String: ', 'bold'), colored("\"$source_string\"", 'bright_red');
    for (@$entry) {
        my ($path, $line) = @$_;
        note colored('  --> Location: ', 'bold'), colored($path, 'underline');
        my @lines = $path->lines;
        note colored("\t$line | " . $lines[$line - 1], 'bright_black');
    }
    $$is_ok = 0;
}

sub _validate_string {
    my ($source_string, $entry) = @_;
    my $is_ok = 1;

    _log_fail('Should not start with space nor should have any direct variable.', $source_string, $entry, \$is_ok)
        if ($source_string =~ /^\s|\$/);

    _log_fail('Should not contain field names. Please use placeholder instead.', $source_string, $entry, \$is_ok)
        if ($source_string =~ /_/);    # We can only check for underscore as of now

    return $is_ok;
}

# get parent directory for e.g. /home/git/regentmarkets
my $directory = dirname(dirname(__DIR__));

subtest 'validate localize string structure' => sub {
    foreach my $repository (@repositories_containing_localize) {
        my $current_repo_directory = $directory . '/' . $repository;

        subtest "validating files for $current_repo_directory" => sub {
            my $Ext = _get_locale_extract();
            my @pmfiles = File::Find::Rule->file->name('*.pm', '*.cgi')->in($current_repo_directory);
            foreach my $sub_dir (@pmfiles) {
                $Ext->extract_file(path($sub_dir)->realpath);
            }
            $Ext->compile();

            my $passed_count = 0;

            my $entries = $Ext->compiled_entries();
            foreach my $string_to_translate (keys %{$entries}) {
                $passed_count++ if (_validate_string($string_to_translate, $entries->{$string_to_translate}));
            }

            unless (keys %{$entries}) {
                ok(1, colored("No string to check in $current_repo_directory", 'yellow'));
            } elsif ($passed_count > 0) {
                ok(1, colored("$passed_count strings found to be OK in $current_repo_directory", 'green'));
            }
        };
    }
};

done_testing();
