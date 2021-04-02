package BOM::User::Script::P2PDailyMaintenance;

use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Config::Runtime;
use LandingCompany::Registry;
use Log::Any qw($log);
use Syntax::Keyword::Try;

use constant CRON_INTERVAL_DAYS => 1;

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

    for my $broker (keys $self->{brokers}->%*) {
        try {
            my $db = $self->{brokers}{$broker}{db};

            if ($archive_days > 0) {
                $db->run(
                    fixup => sub {
                        $_->do('SELECT p2p.deactivate_old_ads(?)', undef, $archive_days);
                    });
            }

            $db->run(
                fixup => sub {
                    $_->do('SELECT p2p.advertiser_completion_refresh(?)', undef, CRON_INTERVAL_DAYS);
                });

        } catch ($e) {
            $log->errorf('Error processing broker %s: %s', $broker, $e);
        }
    }

    return 0;
}

1;
