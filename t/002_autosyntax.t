use strict;

use Test::More;
use Test::Syntax::Aggregate;
use File::Find::Rule;
use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use Test::Strict;
use Cwd;

my $pattern = $ARGV[0];    # confines test to just files matching this pattern.

#subtest "Check modules in lib" => sub {
#    for (sort File::Find::Rule->file->name(qr/\.p[lm]$/)->in(Cwd::abs_path)) {
#        /$pattern/ || next if $pattern;
#        syntax_ok($_) if $_ =~ /\.pl$/;
     # Disabling critic tests for now since I don't want to flood the review process.
     # will do a separate branch after which addresses these.
     #   critic_ok($_);
#    }
#};
subtest "Check modules in bin" => sub {
    for (sort File::Find::Rule->file->name(qr/\.p[lm]$/)->in(Cwd::abs_path . '/../bin')) {
        /$pattern/ || next if $pattern;
        syntax_ok($_) if $_ =~ /\.pl$/;
    }
};

done_testing;
