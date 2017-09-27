#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use Bloomberg::RequestFiles;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my $request_file = Bloomberg::RequestFiles->new();
eval { $request_file->generate_request_files('scheduled') };    ## no critic (RequireCheckingReturnValueOfEval)
print "Files being generated to /tmp/. You can ask system admin to copy the files for your view.";
code_exit_BO();
