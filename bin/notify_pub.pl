use strict;
use warnings;
use 5.010;
use YAML::XS;
use DBI;
use RedisDB;
use JSON;


my $config = YAML::XS::LoadFile('/etc/rmg/clientdb.yml');
my $conn;
foreach my $lc (keys %{$config}) {
  if (ref $config->{$lc}){
    $conn->{$config->{$lc}->{write}->{ip}} = $config->{password};
  }
}

say "Process ID: $$";
my $forks = 0;

sub _redis {
    my $config = YAML::XS::LoadFile('/etc/rmg/chronicle.yml');
    return RedisDB->new(
        host     => $config->{write}->{host},
        port     => $config->{write}->{port},
        password => $config->{write}->{password});
}


foreach my $ip (keys %{$conn}) {
  my $pid = fork;
  if (not defined $pid) {
     die 'Could not fork';
     next;
  }
  if ($pid) {
    $forks++;
    say "In the parent process PID ($$), Child pid: $pid Num of fork child processes: $forks";
  } else {
    say "In the child process PID ($$)";
    say "starting to listen to $ip";

    my $dbh = DBI->connect("dbi:Pg:dbname=regentmarkets;host=$ip;port=5432", 'write', $conn->{$ip}, {AutoCommit => 1, RaiseError => 1, PrintError => 1});

    $dbh->do("LISTEN transaction_watchers");

    my $redis = _redis();

    LISTENLOOP: {
      while (my $notify = $dbh->pg_notifies) {
        my ($name, $pid, $payload) = @$notify;
        my @items = split(',', $payload);
        my $msg;
        $msg->{id} = $items[0];
        $msg->{account_id} = $items[1];
        $msg->{action_type} = $items[2];
        $msg->{referrer_type} = $items[3];
        $msg->{financial_market_bet_id} = $items[4];
        $msg->{payment_id} = $items[5];
        $msg->{amount} = $items[6];
        $msg->{balance_after} = $items[7];
        say "(PUBLISH:".'balance_'.$msg->{account_id}.")";
        $redis->publish('balance_'.$msg->{account_id}, JSON::to_json($msg));
        $redis->publish('buy_'.$msg->{account_id}, JSON::to_json($msg));
        $redis->publish('sell_'.$msg->{account_id}, JSON::to_json($msg));
        $redis->publish('transaction_'.$msg->{account_id}, JSON::to_json($msg));
        $redis->publish('payment_'.$msg->{account_id}, JSON::to_json($msg));
        say "($name, $pid, $payload)";
      }
      $dbh->ping() or die qq{Ping failed!};
      sleep(1);
      redo;
    }


    say "Child ($$) exiting";
    exit;
  }
}

for (1 .. $forks) {
   my $pid = wait();
   say "Parent saw $pid exiting";
}
say "Parent ($$) ending";