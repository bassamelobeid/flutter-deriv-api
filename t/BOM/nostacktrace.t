#!perl

# We are using Error::Base->cuss() a lot. The main purpose is to send a structured
# message back to the caller. Using this module is quite unfortunate because it
# creates a stack trace every time it's called which we are not using at all, at
# least I could not find places where we use it. We might want to refactor this
# code to get rid of this Error::Base. But until then, adding -quiet=>1 prevents
# the stack trace and thus also the exception thrown when the stack is deeper
# than 99.

# This test is to make sure the option works as expected.

# When Error::Base is eliminted, this entire test can also be deleted.

use 5.024;    # to use __SUB__->()

use strict;
use warnings;
no warnings qw/recursion/;    # silence perl's internal deep recursion warning

use Test::More 'no_plan';
use Test::Exception;
use Error::Base;

sub rec {
    my $lim     = shift;
    my $payload = shift;
    my $lvl     = shift // 0;
    if ($lvl < $lim) {
        __SUB__->($lim, $payload, $lvl + 1);
    } else {
        $payload->();
    }
}

lives_ok {
    rec(93, sub { Error::Base->cuss(-mesg => 'bla') });
}
'lives at level 93';

throws_ok {
    rec(94, sub { Error::Base->cuss(-mesg => 'bla') });
}
qr/Error::Base internal error: excessive backtrace/, 'dies at level 94';

lives_ok {
    rec(94, sub { Error::Base->cuss(-quiet => 1, -mesg => 'bla') });
}
'except if -quiet=>1 is given';

rec(
    $_,
    sub {
        use Time::HiRes ();
        my $start       = [Time::HiRes::gettimeofday];
        my $stack_depth = 1;
        1 while defined scalar caller($stack_depth += 10);
        1 until defined scalar caller --$stack_depth;
        note "stack_depth=$stack_depth, elapsed: " . (1000000 * Time::HiRes::tv_interval($start));
    }
    ) for (
    90 .. 110,
    2091
    );

done_testing;
