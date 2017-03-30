use strict;
use warnings;
use Test::More tests => 7;
use BOM::Transaction;

my $error = BOM::Transaction::format_error(err => ['BI103']);
isa_ok($error, "Error::Base");
is($error->get_type, 'RoundingExceedPermittedEpsilon');
is($error->get_mesg, 'Rounding exceed permitted epsilon');

$error = BOMK::Transaction::format_error(err => "random error");
isa_ok($error, "Error::Base");
is($error->get_type,             'InternalError');
is($error->get_mesg,             'random error');
is($error->{-message_to_client}, 'Internal Error');

