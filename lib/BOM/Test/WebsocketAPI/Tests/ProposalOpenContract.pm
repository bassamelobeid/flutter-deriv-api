package BOM::Test::APITester::Tests::ProposalOpenContract;

no indirect;

use strict;
use warnings;

use Future::Utils qw(fmap_void);

use Devops::BinaryAPI::Tester::DSL;

=head2 proposal_open_contract

Buys a contract and test proposal_open_contract stream.
This only tests for missing ticks, duplicated responses ignored for now.

=cut

suite proposal_open_contract => sub {
    my ($suite, %args) = get_args(@_);

    my $context = $suite->last_context;

    fmap_void {
        my $params = shift;

        $context
        ->connection($args{connection_params}->%*)
        ->subscribe($params->%*)
        ->take_until(sub {
            return shift->{body}->{is_expired};
        })
        ->expect_done(sub {
            note 'Start time: ' . shift->{body}->{start_time}; # first response (buy)
            my (@poc_list) = @_;

            my $last_tick_time;
            for my $poc (@poc_list) {
                my $current_spot_time = $poc->{body}->{current_spot_time};

                if (!$last_tick_time) {
                    note 'Got the first poc response: ' . $current_spot_time;
                } elsif ($current_spot_time == $last_tick_time) {
                    note 'Got duplicated tick: ' . $current_spot_time;
                } else {
                    is $current_spot_time, $last_tick_time + 2, 'Got the next tick: ' . $current_spot_time;
                }
                $last_tick_time = $current_spot_time;
            }
        })
        ->helper::log_method(keys $params->%*)
        ->completed
    } foreach => $args{subscription_list}, concurrent => $args{concurrent}
};

sub get_args {
    my ($suite, %args) = @_;

    $args{concurrent}        //= 1;
    $args{connection_params} //= { map { $_ => $args{$_} } grep { /\bclient|token/ } keys %args };
    $args{subscription_list}   = [ $args{subscription_list}->@* ];

    return ($suite, %args);
}

1;
