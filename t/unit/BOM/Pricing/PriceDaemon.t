use strict;
use warnings;
use Test::More;
use BOM::Pricing::PriceDaemon;
is(1, 1, "1 is 1");



    my $daemon = BOM::Pricing::PriceDaemon->new(
        tags                 => ['tag:test' ],
        record_price_metrics => 0,
        price_duplicate_spot => 0,
    );
is $daemon ,'123';
 $daemon->stop;
ok !$daemon->is_running , 'is not running';

my $pid=fork();
if ($pid){
is $pid, 0 ,'subprocess';
}else{
is $pid, 0 ,'$pid';

}

$daemon->run(      queues     => ['tests']);
done_testing();
