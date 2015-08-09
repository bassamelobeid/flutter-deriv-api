package BOM::WebSocketAPI::BaseController;

use Mojo::Base 'Mojolicious::Controller';

use Data::Dumper;

=head1 DESCRIPTION

Base Class for BOM::WebAPI Controllers.

=cut

=head1 METHODS

=head2 _fail

Failure Handler

A comprehensive failure handler: log the problem first then return the bad news in a
standard error result template.

=cut

# why don't we use .ep templates for these? Because the built-in
# json format handler does it better.

sub _fail {
    my $c       = shift;
    my $message = shift || 'failed';
    my $code    = shift || 400;        # 400 == Bad Request
    my $climsgs = shift;
    my $logmsgs = shift || $climsgs;
    my $log     = $c->app->log;
    $log->error("failing: $message");
    $log->error("details: " . Dumper($logmsgs)) if $logmsgs;
    my $fault = {
        faultstring => $message,
        faultcode   => $code
    };

    if ($climsgs) {
        my $slot = ref $climsgs ? 'details' : 'detail';
        $fault->{$slot} = $climsgs;
    }
    $c->render(
        json   => {fault => $fault},
        status => $code
    );
    return;
}

=head2 _pass

Success Handler

A general purpose success handler.  Dump the generated json to the log
(unless asked not to)
then return the result using built-in json format conversion.

=cut

sub _pass {
    my $c       = shift;
    my $data    = shift;
    my $logdata = shift;
    my $log     = $c->app->log;

    if ($log->is_debug) {
        if ($logdata) {
            $c->app->log->debug('return memo ' . Dumper($logdata));
        } else {
            $c->app->log->debug('returning ' . Dumper($data));
        }
    }
    return $c->render(json => $data);
}

1;
