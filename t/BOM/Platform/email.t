use strict;
use warnings;
use Test::More;
use Email::Sender::Transport::Test;
use Test::MockModule;
use Test::Warnings qw(warning);
use Brands;
use BOM::Platform::Context qw(request);

BEGIN {use_ok('BOM::Platform::Email', qw(send_email));}

my $transport  = Email::Sender::Transport::Test->new;
my $mocked_stuffer = Test::MockModule->new('Email::Stuffer');
$mocked_stuffer->mock(
    'send',
    sub {
        my $self = shift;
        $self->transport($transport);
        $mocked_stuffer->original('send')->($self, @_);
    });

my $args = {};
my $result;
subtest 'args' => sub {
    like(warning { $result = send_email($args); }, qr/missed/ , 'no email address');
    ok(!$result, 'failed because no to email');
    $args->{to} = 'test@test.com';
    like(warning { $result = send_email($args); }, qr/missed/ , 'no from email address');
    ok(!$result, 'failed because no from email');
    $args->{from} = 'from@test.com';
    like(warning { $result = send_email($args); }, qr/missed/ , 'no subject');
    ok(!$result, 'failed because no subject');
    local $ENV{SKIP_EMAIL} = 1;
    $args->{subject} = "Test subject";
    ok(send_email($args), 'result success but in fact not email not sent');
    is scalar($transport->deliveries), 0, "not called yet";
    local $ENV{SKIP_EMAIL} = 0;
    $args->{to} = "hello";
    like(warning { $result = send_email($args); }, qr/erroneous email address/ , 'bad email address');
    ok(!$result, 'failed because of bad email address');
    done_testing();
};

subtest 'support address' => sub{
  $args->{to} = 'test@test.com';
  my $brand = Brands->new(name => request()->brand);
  $args->{from} = $brand->emails('support');
  ok(send_email($args));
  is_deeply([$transport->deliveries]->[-1]{successes}, ['test@test.com'], 'send email ok');
  

};


done_testing();
