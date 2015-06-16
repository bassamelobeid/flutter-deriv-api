package BOM::Test::EasyLogging;
use strict;
use warnings;

=head1 NAME

BOM::Test::EasyLogging;

=head1 SYNOPSIS

    use BOM::Test::EasyLogging;

=head1 DESCRIPTION

This module enables logging to console and sets log level to DEBUG
or FATAL depending on the presence of HARNESS_IS_VERBOSE environment variable.
Just include this module in your test.

=cut

## no critic
$ENV{BOM_CONSOLE_LOGGING} = $ENV{HARNESS_IS_VERBOSE} ? 'DEBUG' : 'FATAL';

1;
