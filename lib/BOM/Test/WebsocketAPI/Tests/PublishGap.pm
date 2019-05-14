package BOM::Test::WebsocketAPI::Tests::PublishGap;

no indirect;

use strict;
use warnings;

use Future::Utils qw( fmap0 );
use Future::AsyncAwait;

use Devops::BinaryAPI::Tester::DSL;

suite publish_gap => sub {
    my ($suite, %args) = @_;

    my $requests = $args{requests};
    my $context = $suite
    ->last_context
    ->connection(exists $args{token} ? %args{token} : ());
    fmap0 {
        my ($method, $request) = $_->%*;

        my $published_method = $method;
        $published_method = 'proposal_open_contract' if $method eq 'buy';
        return Future->done if $method eq 'ticks_history';
        $published_method = 'tick' if $method eq 'ticks';

        $context
        ->subscribe($method, $request)
        ->pause_publish($published_method)
        ->skip_until_publish_paused($published_method)
        # Wait 1 second to make sure no previous publish will be received
        ->chain(sub { shift->completed->then(sub { $suite->tester->loop->delay_future(after => 2) }) })
        ->timeout_ok(2, sub { shift->take_latest })
        ->resume_publish($published_method)
        ->take_latest
        ->helper::log_method($request)
        ->completed
    } foreach => [$requests->@*], concurrent => scalar($requests->@*);
};

1;
