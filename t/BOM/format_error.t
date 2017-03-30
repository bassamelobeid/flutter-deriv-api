use strict;
use warnings;
use Test::More tests => 7;
use BOM::Transaction;

my $error = BOM::Transaction->format_error(err => ['BI103']);
isa_ok($error, "Error::Base", 'object type is Error::Base');
is($error->get_type, 'RoundingExceedPermittedEpsilon',    'error type ok');
is($error->get_mesg, 'Rounding exceed permitted epsilon', 'error message ok');

$error = BOM::Transaction->format_error(err => "random error");
isa_ok($error, "Error::Base", 'object type ok');
is($error->get_type,             'InternalError',  'error type ok');
is($error->get_mesg,             'random error',   'error message ok');
is($error->{-message_to_client}, 'Internal Error', 'client message ok');

