use strict;
use warnings;
use Test::More;
use Test::MockObject::Extends;
use FindBin;

# Since this is testing a class within a script file things are a bit different to usual.
# Test::MockObject::Extends allows us to add a mock to an established object so works here where
# Test::MockModule wont be able to find the module.

require $FindBin::Bin . '/../../bin/proposal_sub.pl';

# Duration
subtest 'Duration: When min and max are ticks result is between' => sub {
    my $load_runner = LoadTest::Proposal->new();
    my @duration    = $load_runner->durations('1t', '10t');
    ok(($duration[0] >= 1 and $duration[0] <= 10), 'Duration is between min and max');
};

subtest 'Duration test max and min boudaries' => sub {
    my $load_runner = LoadTest::Proposal->new();
    $load_runner = Test::MockObject::Extends->new($load_runner);
    $load_runner->mock(random_generator => sub { return 10 });

    my @duration = $load_runner->durations('1t', '10t');
    is($duration[0], 10, 'Max duration correct');

    $load_runner = LoadTest::Proposal->new();
    $load_runner = Test::MockObject::Extends->new($load_runner);
    $load_runner->mock(random_generator => sub { return 1 });
    @duration = $load_runner->durations('1t', '10t');
    is($duration[0], 1, 'Min duration correct');
};

subtest 'Duration handles min of type hour and max of type day less than 1 day' => sub {

    my $load_runner = LoadTest::Proposal->new();
    $load_runner = Test::MockObject::Extends->new($load_runner);
    $load_runner->mock(random_generator => sub { return 10 });
    my @duration = $load_runner->durations('1m', '10d');
    is($duration[0], 10,  'Duration correct');
    is($duration[1], 'm', 'Duration type is minutes');
};

subtest 'Duration handles min of type hour and max of type day greater than 1 day' => sub {
    my $load_runner = LoadTest::Proposal->new();
    $load_runner = Test::MockObject::Extends->new($load_runner);
    $load_runner->mock(random_generator => sub { return 4000 });
    my @duration = $load_runner->durations('1m', '10d');
    is($duration[0], 2,   'Duration correct');
    is($duration[1], 'd', 'Duration type is minutes');
};

subtest 'Duration handles days greater than 1 ' => sub {
    my $load_runner = LoadTest::Proposal->new();
    $load_runner = Test::MockObject::Extends->new($load_runner);
    $load_runner->mock(random_generator => sub { return 3 });
    my @duration = $load_runner->durations('1d', '10d');
    is($duration[0], 3,   'Duration correct');
    is($duration[1], 'd', 'Duration type is days');
};

subtest 'Duration handles minimum duration type of seconds and max type different. ' => sub {
    my $load_runner = LoadTest::Proposal->new();
    $load_runner = Test::MockObject::Extends->new($load_runner);
    $load_runner->mock(random_generator => sub { return 3 });
    my @duration = $load_runner->durations('1s', '10d');
    is($duration[0], 3,   'Duration correct');
    is($duration[1], 'm', 'Duration type when minimum is seconds is converted to minutes');
};
subtest 'Duration handles ticks when minimum and max type different.' => sub {
    my $load_runner = LoadTest::Proposal->new();
    $load_runner = Test::MockObject::Extends->new($load_runner);
    $load_runner->mock(random_generator => sub { return 3 });
    my @duration = $load_runner->durations('1t', '10s');
    is($duration[0], 3,   'Duration correct');
    is($duration[1], 's', 'Duration type when minimum is ticks and max is seconds converted to seconds');
    @duration = $load_runner->durations('1t', '10m');
    is($duration[0], 3,   'Duration correct');
    is($duration[1], 'm', 'Duration type when minimum is ticks and max is seconds converted to seconds');
};
done_testing();
