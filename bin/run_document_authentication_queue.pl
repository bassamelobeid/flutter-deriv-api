#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long 'GetOptions';
use Log::Any qw($log);
use Log::Any::Adapter;
use BOM::Event::Listener;

GetOptions
    'log-level=s' => \my $log_level;

Log::Any::Adapter->set('Stderr', log_level => $log_level // 'info');

$log->debugf('Starting document listener');
BOM::Event::Listener->run('DOCUMENT_AUTHENTICATION_QUEUE');
$log->debugf('Ending document listener');
