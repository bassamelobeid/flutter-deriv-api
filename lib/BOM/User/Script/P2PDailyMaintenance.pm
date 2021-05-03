package BOM::User::Script::P2PDailyMaintenance;

use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use LandingCompany::Registry;
use Log::Any qw($log);
use Syntax::Keyword::Try;

use constant CRON_INTERVAL_DAYS => 1;
use constant REDIS_KEY          => 'P2P::AD_ARCHIVAL_DATES';

=head1 Name

P2PDailyMaintenance - daily P2P housekpeeing tasks

=cut

=head2 new

Initialize db connections.

=cut

sub new {
    my $class   = shift;
    my $self    = {};
    my @brokers = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
    $self->{brokers}{$_}{db} = BOM::Database::ClientDB->new({broker_code => uc $_})->db->dbic for @brokers;
    return bless $self, $class;
}

=head2 run

Execute db functions.

=cut

sub run {
    my $self = shift;

    my $archive_days = BOM::Config::Runtime->instance->app_config->payments->p2p->archive_ads_days;
    my %archival_dates;

    for my $broker (keys $self->{brokers}->%*) {
        try {
            my $db = $self->{brokers}{$broker}{db};

            if ($archive_days > 0) {
                my $updates = $db->run(
                    fixup => sub {
                        $_->selectall_arrayref('SELECT * FROM p2p.deactivate_old_ads(?)', {Slice => {}}, $archive_days);
                    });

                $archival_dates{$_->{id}} = $_->{archive_date} for @$updates;
            }

            $db->run(
                fixup => sub {
                    $_->do('SELECT p2p.advertiser_completion_refresh(?)', undef, CRON_INTERVAL_DAYS);
                });

        } catch ($e) {
            $log->errorf('Error processing broker %s: %s', $broker, $e);
        }
    }

    my $redis = BOM::Config::Redis->redis_p2p_write();
    $redis->multi;
    $redis->del(REDIS_KEY);
    $redis->hset(REDIS_KEY, $_, $archival_dates{$_}) for keys %archival_dates;
    $redis->expire(REDIS_KEY, $archive_days * 24 * 60 * 60);
    $redis->exec;

    return 0;
}

1;
