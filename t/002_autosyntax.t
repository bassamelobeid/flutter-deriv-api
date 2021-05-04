use strict;
use warnings;

use Test::More;
use Test::Syntax::Aggregate;
use File::Find::Rule;
use Test::Strict;
use Cwd;

subtest "Check modules in lib" => sub {
    pass 'Syntax check starts here';
    for (sort File::Find::Rule->file->name(qr/\.p[lm]$/)->in(Cwd::abs_path . '/lib')) {
        syntax_ok($_) if $_ =~ /\.pl$/;
    }
};

done_testing;
