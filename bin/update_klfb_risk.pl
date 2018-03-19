#!/etc/rmg/bin/perl
use strict;
use warnings;
use JSON::MaybeXS;
use BOM::Database::ClientDB;
use Date::Utility;
use BOM::Platform::RedisReplicated;

my $klfb_risk_cache = BOM::Platform::RedisReplicated::redis_read()->get('klfb_risk::JP');
if (undef $klfb_risk_cache) {

    my $clientdb = BOM::Database::ClientDB->new({
        broker_code => 'JP',
        operation   => 'replica',
    });
    my $date               = Date::Utility->new;
    my $month              = $date->month;
    my $year               = $date->year;
    my $beginning_of_month = Date::Utility->new($year . '-' . $month . '-' . 01);
    my $json               = JSON::MaybeXS->new;
    my $limit              = $json->encode({'klfb_risk_limit' => {'tstmp' => $beginning_of_month->db_timestamp}});
    my $risk =
        $clientdb->getall_arrayref('select * from bet_v1.klfb_risk_limit(?,?,?,?)', [undef, undef, undef, $limit])->[0]->{klfb_risk_limit}->{current};

    BOM::Platform::RedisReplicated::redis_write()->set('klfb_risk::JP', $risk, 'EX', 24 * 60 * 60);

    return;
}
