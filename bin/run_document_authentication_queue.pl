#!/usr/bin/env perl
use strict;
use warnings;

use Log::Any::Adapter qw(Stderr), log_level => 'debug';

use Log::Any qw($log);
use BOM::Event::Listener;

$log->infof('Starting document listener');
BOM::Event::Listener->run('DOCUMENT_AUTHENTICATION_QUEUE');
$log->infof('Ending document listener');
