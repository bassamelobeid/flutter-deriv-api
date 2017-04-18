use strict;
use warnings;
use Test::More;
use Email::Sender::Transport::Test;
use Test::MockModule;
use Test::Warnings qw(warning);
use Brands;
BEGIN {use_ok('BOM::Platform::Email', qw(send_email));}

my $transport_obj  = Email::Sender::Transport::Test->new;
my $mocked_stuffer = Test::MockModule->new('Email::Stuffer');
$mocked_stuffer->mock(
    'send',
    sub {
        my $self = shift;
        $self->transport($mocked_stuffer);
        $self->send(@_);
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
    is $transport_obj->successes, 0, "not called yet";
    done_testing();
};

done_testing();
