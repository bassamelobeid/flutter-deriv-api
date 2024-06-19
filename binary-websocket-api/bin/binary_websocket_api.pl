#!/etc/rmg/bin/perl

use strict;
use warnings;
use FindBin;
use Log::Any::Adapter 'DERIV',
    log_level => 'info',
    stderr    => 'json';
# Mojo will redirect STDERR without autoflush, so we should set autoflush by hand
*STDERR->autoflush(1);
use Log::Any qw($log);
# load this file to force MOJO::JSON to use JSON::MaybeXS
use Mojo::JSON::MaybeXS;
use lib "$FindBin::Bin/../lib";
use Mojo::WebSocketProxy::RequestLogger;

# set the default handler for Log::Any to use Deriv adapter for context logging
Mojo::WebSocketProxy::RequestLogger->set_handler(
    sub {
        my ($level, $message, $context, @params) = @_;
        $log->adapter->set_context($context);
        $log->$level($message, @params);
        $log->adapter->clear_context;
    });

# There does not appear to be any specific handling for
# output layers in Mojolicious::Commands, so we need to
# set this ourselves.
binmode STDERR, ':encoding(UTF-8)';

# Start command line interface for application
require Mojolicious::Commands;
Mojolicious::Commands->start_app('Binary::WebSocketAPI');

