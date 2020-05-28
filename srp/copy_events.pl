#!/usr/bin/env perl

use strict;
use warnings;
no indirect;

use Log::Any qw($log);

use Syntax::Keyword::Try;
use BOM::Platform::Event::Emitter;
use JSON::MaybeUTF8 qw(:v1);

my $read = BOM::Platform::Event::Emitter::_read_connection();
my $range_list = $read->lrange('CRYPTO_EVENTS_QUEUE', 0, -1);

for my $transaction ($range_list->@*) {
    my $decoded_data = decode_json_utf8($transaction);
    next unless ($decoded_data->{type} eq 'set_pending_transaction');

    my ($emit, $error);
    try {
        $emit = BOM::Platform::Event::Emitter::emit('crypto_subscription', $transaction);
    }
    catch {
        $error = $@;
    }
    warn $error unless $emit;
}
