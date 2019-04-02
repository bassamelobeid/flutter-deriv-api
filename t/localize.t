use strict;
use warnings;

use Locale::Maketext::Extract;
use File::Find::Rule;
use Test::Most;
use Path::Tiny;
use Dir::Self;
use File::Basename;

my @repositories_containing_localize = qw/bom-pricing bom-platform bom-cryptocurrency bom-transaction bom-rpc bom-events/;

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

# get parent directory for e.g. /home/git/regentmarkets
my $directory = dirname(dirname(__DIR__));

subtest 'validate localize string structure' => sub {
    foreach my $repository (@repositories_containing_localize) {
        my $current_repo_directory = $directory . '/' . $repository;

        subtest "validating files for $current_repo_directory" => sub {
            my $Ext     = _get_locale_extract();
            my @pmfiles = File::Find::Rule->file->name("*.pm")->in($current_repo_directory);
            foreach my $sub_dir (@pmfiles) {
                $Ext->extract_file(path($sub_dir)->realpath);
            }
            $Ext->compile();

            foreach my $string_to_translate (keys %{$Ext->compiled_entries()}) {
                unlike($string_to_translate, qr/^\s|\$/, 'Strings to be translated should not start with space nor should have any direct variable.');
            }
        };
    }
};

done_testing();
