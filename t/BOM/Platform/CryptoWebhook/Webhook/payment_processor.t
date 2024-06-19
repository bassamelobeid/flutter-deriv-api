use strict;
use warnings;

use Test::More;
use Test::Warnings;

use BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor;

my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');
my $unknown   = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Unknown');

isa_ok $coinspaid, "BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid", 'Returns the correct instance.';
is $unknown, undef, 'Returns the correct result when package file does not exists.';

done_testing;

