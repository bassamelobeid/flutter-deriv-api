
use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Deep;
use BOM::Event::Utility;

my $mock_bom_events_util = Test::MockModule->new('BOM::Event::Utility');

my @datadog_tags = ();
$mock_bom_events_util->mock(
    '_add_metric_on_exception' => sub {
        my ($caller) = @_;
        my @tags = BOM::Event::Utility::_convert_caller_to_array_of_tags($caller);
        @datadog_tags = @tags;
        return undef;
    });

subtest 'exception_logged tests' => sub {

    package TryLoggedTestPackage;

    use strict;
    use warnings;
    use Future::AsyncAwait;
    use Test::More;
    use Test::Exception;
    use Test::Deep;
    use Syntax::Keyword::Try;
    use BOM::Event::Utility qw(exception_logged);

    sub sub_exception_logged {
        try {
            die "something is wrong!!";
        }
        catch {
            my $e = $@;
            exception_logged();
        }
        return 1;
    }

    @datadog_tags = ();
    lives_ok { TryLoggedTestPackage::sub_exception_logged() } "sub_exception_logged lives_ok";
    my @expected = (lc 'package:TryLoggedTestPackage', lc 'method:sub_exception_logged');
    is_deeply(\@datadog_tags, \@expected, 'correct datadog tags.');
};

done_testing();

