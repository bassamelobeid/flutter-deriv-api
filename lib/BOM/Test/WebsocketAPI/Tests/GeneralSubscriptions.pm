package BOM::Test::APITester::Tests::GeneralSubscriptions;

no indirect;

use strict;
use warnings;

use Future::Utils qw(try_repeat);

use Devops::BinaryAPI::Tester::DSL;

sub get_args {
    my ($suite, %args) = @_;

    $args{connection_params} //= { map { $_ => $args{$_} } grep { /\bclient|token/ } keys %args };

    return ($suite, %args);
}

=head2 restart_redis

Restart Redis simultaneously with subscriptions and see if the subscription is
not affected.

=cut

suite restart_redis => sub {
    my ($suite, %args) = get_args(@_);

    (try_repeat {
        my ($method, $request) = shift->%*;

        $suite
        ->connection($args{connection_params}->%*)
        ->subscribe($method, $request)
        ->restart_redis
        ->take_latest
        ->helper::log_method($method)
        ->completed
    } foreach => [ $args{subscription_list}->@* ])
};

1;
