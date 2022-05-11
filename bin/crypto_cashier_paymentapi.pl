#!/usr/bin/env perl

use strict;
use warnings;

use Mojolicious::Commands;
use Log::Any::Adapter qw(DERIV),
    stderr    => 'json',
    log_level => $ENV{BOM_LOG_LEVEL} // 'info';

Mojolicious::Commands->start_app('BOM::Platform::CryptoCashier::Payment::API');
