package BOM::WebSocketAPI::v1::BaseController;

use Mojo::Base 'Mojolicious::Controller';

use Data::Dumper;

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
