use strict;
use warnings;
use Test::More;
use Test::Exception;
use Email::Sender::Transport::Test;
use Test::MockModule;
use Test::Warnings;
use Brands;
use_ok('BOM::Platform::Email');

my $transport_obj  = Email::Sender::Transport::Test;
my $mocked_stuffer = Test::MockModule('Email::Stuffer');
$mocked_stuffer->mock(
    'send',
    sub {
        my $self = shift;
        $self->transport($mocked_stuffer);
        $self->send(@_);
    });

my $args = {};

subtest 'args' => sub {
    throw_ok { send_email($args) } 'No email provided';
    $args->{to} = 'test@test.com';
    ok !send_email, 'failed because no email';
    my $result;
    like(warning { $result = send_email($args) } , qr/from email missing/);
    ok !result, "failed because no from email";
    $args->{from} = 'from@test.com';
    like(warning { $result = send_email($args) } , qr/from email missing/);
    local $ENV{SKIP_EMAIL} = 1;
    $args->{subject} = "Test subject";
    ok(send_email($args), 'result success but in fact not email not sent');
    is $transport_obj->successes, 0, "not send yet";
    done_testing;

    };

done_testing();
