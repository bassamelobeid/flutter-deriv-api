package BOM::System::Chronicle;

use strict;
use warnings;

use feature "state";
use YAML::XS;
use JSON;
use RedisDB;
use DBI;

sub add {
    my $category = shift;
    my $name     = shift;
    my $value    = shift;

    my $key = $category . '::' . $name;
    _redis_write()->set($key, $value);
    _archive($category, $name, $value) if _dbh();
    return 1;
}

sub get {
    my $category = shift;
    my $name     = shift;

    my $key = $category . '::' . $name;
    return _redis_read()->get($key);
}

sub get_for {
    my $category = shift;
    my $name     = shift;
    my $date_for = shift;

    return _dbh()->selectall_hashref(q{SELECT * FROM chronicle where category=? and name=? and timestamp<=? order by timestamp desc limit 1},
        'id', {}, $category, $name, $date_for);
}

sub _archive {
    my $category = shift;
    my $name     = shift;
    my $value    = shift;

    return _dbh()->prepare(q{INSERT INTO chronicle (id, timestamp, category, name, value) VALUES (DEFAULT,DATE_TRUNC('second', now()),?,?,?)})
        ->execute($category, $name, $value);
}

sub _redis_write {
    state $redis_write = RedisDB->new(
        host     => _config()->{write}->{host},
        port     => _config()->{write}->{port},
        password => _config()->{write}->{password});
    return $redis_write;
}

sub _redis_read {
    state $redis_read = RedisDB->new(
        host     => _config()->{read}->{host},
        port     => _config()->{read}->{port},
        password => _config()->{read}->{password});
    return $redis_read;
}

sub _dbh {
    return if not defined _config()->{chronicle};

    state $dbh = DBI->connect_cached(
        "dbi:Pg:dbname=chronicle;port=5437;host=" . _config()->{chronicle}->{ip},
        "write",
        _config()->{chronicle}->{password},
        {
            RaiseError => 1,
        });
    return $dbh;
}

sub _config {
    state $config = YAML::XS::LoadFile('/etc/chronicle.yml');
    return $config;
}

1;
