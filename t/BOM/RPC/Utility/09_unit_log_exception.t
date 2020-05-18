use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Deep;
use BOM::RPC::v3::Utility;

my $mock_bom_rpcs_util = Test::MockModule->new('BOM::RPC::v3::Utility');

my @datadog_tags = ();
$mock_bom_rpcs_util->mock(
    '_add_metric_on_exception' => sub {
        my ($caller) = @_;
        my @tags = BOM::RPC::v3::Utility::_convert_caller_to_array_of_tags($caller);
        @datadog_tags = @tags;
        return undef;
    });

subtest 'log_exception tests' => sub {

    package TryLoggedTestPackage;

    use strict;
    use warnings;
    use Future::AsyncAwait;
    use Test::More;
    use Test::Exception;
    use Test::Deep;
    use Syntax::Keyword::Try;
    use BOM::RPC::v3::Utility qw(log_exception);

    sub sub_log_exception {
        try {
            die "something is wrong!!";
        }
        catch {
            my $e = $@;
            log_exception();
        }
        return 1;
    }

    @datadog_tags = ();
    lives_ok { TryLoggedTestPackage::sub_log_exception() } "sub_log_exception lives_ok";
    my @expected = (lc 'package:TryLoggedTestPackage', lc 'method:sub_log_exception');
    is_deeply(\@datadog_tags, \@expected, 'correct datadog tags.');
};

done_testing();
