use Test::MockTime qw( restore_time set_absolute_time );
use Test::Most;
use Test::MockModule;
use BOM::MarketDataAutoUpdater;

#2022-12-10 is weekend
set_absolute_time(Date::Utility->new('2022-12-10 15:55:55')->epoch);
my $au = BOM::MarketDataAutoUpdater->new();

lives_ok { $au->run } 'run without dying on weekend';
ok $au->is_a_weekend, 'is_a_weekend true';

#2022-12-13 is work day
set_absolute_time(Date::Utility->new('2022-12-13 15:55:55')->epoch);

$au = BOM::MarketDataAutoUpdater->new();

lives_ok { $au->run } 'run without dying on workday';
ok !$au->is_a_weekend, 'is_a_weekend false on workday';

$au->report->{frxUSDJPY}->{success} = 'updated';
$au->report->{error} = ['error'];

my $mocked_email = Test::MockModule->new('Email::Stuffer');
$mocked_email->mock('send_or_die' => sub { return 'sending email'; });

#set time off 2 hours later
set_absolute_time(Date::Utility->new('2022-12-13 17:55:55')->epoch);

is $au->run, 'sending email', 'sending email after an hour';

done_testing;

restore_time();
