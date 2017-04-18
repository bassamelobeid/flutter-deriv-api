use strict;
use warnings;
use Test::More;
use Test::Exception;
use Email::Sender::Transport::Test;
use Test::MockModule;
use_ok('BOM::Platform::Email');

my $transport_obj = Email::Sender::Transport::Test;
my $mocked_stuffer = Test::MockModule('Email::Stuffer');
$mocked_stuffer->mock('send', sub{
                        my $self = shift;
                        $self->transport($mocked_stuffer);
                        $self->send(@_);
                      });

send_email({from})

done_testing();
