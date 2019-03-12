package BOM::Test::APITester::Tests::Ticks;

no indirect;

use strict;
use warnings;

use Devops::BinaryAPI::Tester::DSL;

suite ticks_duplicate_subscribe_ok => sub {
    my ($suite, %args) = @_;

    my $symbol = $args{symbol} // 'R_100';
    my $method = $args{method} // 'ticks';

    $suite
    ->connection
    ->subscribe( $method, { $method => $symbol, extra_params($method) } )
    ->as('first')
    ->subscribe( $method, { $method => $symbol, extra_params($method) } )
    ->with('first')
    ->helper::log_method($method)
};

sub extra_params {
    return shift eq 'ticks_history' ? ( end => 'latest' ) : ();
}

1;
