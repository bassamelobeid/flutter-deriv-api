package BOM::MyAffiliates::GenerateRegistrationDaily;

use Moose;
extends 'BOM::MyAffiliates::Reporter';

use Text::CSV;
use Text::Trim;
use Path::Tiny;
use FileHandle;
use Date::Utility;

use LandingCompany;

use BOM::Database::ClientDB;
use BOM::Database::DataMapper::CollectorReporting;
use BOM::Config::Runtime;
use BOM::MyAffiliates::BackfillManager;

use constant HEADERS => qw(
    Date Loginid AffiliateToken
);

has '+include_headers' => (
    default => 0,
);

has new_clients => (
    is         => 'rw',
    lazy_build => 1
);

sub _build_new_clients {
    my $self = shift;

    my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
        operation   => 'collector'
    });

    my $date_to = Date::Utility->new({datetime => $self->processing_date->date_ddmmmyy . ' 23:59:59GMT'})->datetime_yyyymmdd_hhmmss;

    # we don't filter data by brand for registration
    # our client can use any brand - binary and deriv currently - to trade or sign-up
    # myaffiliates to reflect properly in affiliates expect all the registration for
    # brands, also known as channels on myaffiliate side
    my $candidates = $report_mapper->get_unregistered_client_token_pairs_before_datetime({
        to_date => $date_to,
    });
    return $candidates;
}

sub any_new_clients {
    my $self = shift;
    return scalar $self->new_clients;
}

sub report {
    my $self = shift;

    return 0 unless $self->any_new_clients;

    my @output = ();

    my $csv = Text::CSV->new;
    foreach (@{$self->new_clients}) {
        $csv->combine($self->_date_joined($_), $self->prefix_field($_->{loginid}), trim($_->{myaffiliates_token} // ''));
        push @output, $self->format_data($csv->string);
    }
    return @output;
}

sub _date_joined {
    my ($self, $client_data) = @_;
    my $date_joined = $client_data->{date_joined};

    if (!$date_joined) {
        warn("date_joined is empty?! [", $client_data->{'loginid'}, "]: [$date_joined]");
        $date_joined = Date::Utility->new->date_yyyymmdd;
    }
    return Date::Utility->new({datetime => $date_joined})->date_yyyymmdd;
}

sub register_tokens {
    my $self = shift;

    foreach my $broker (LandingCompany::Registry::all_broker_codes) {
        next if ($broker eq 'FOG');

        my @matched_tokens = grep { $_->{'loginid'} =~ /^$broker/ } @{$self->new_clients};

        my $connection_builder = BOM::Database::ClientDB->new({
            broker_code => $broker,
        });
        my $dbic = $connection_builder->db->dbic;

        foreach my $token_data (@matched_tokens) {
            my ($sql, $bind_param);

            if ($token_data->{is_creative} or $token_data->{signup_override}) {
                $sql = q{
                    UPDATE betonmarkets.client_affiliate_exposure
                    SET myaffiliates_token_registered = TRUE
                    WHERE id = ?
                };
                $bind_param = $token_data->{'id'};
            } else {
                $sql = q{
                    UPDATE betonmarkets.client
                    SET myaffiliates_token_registered = TRUE
                    WHERE loginid = ?
                };
                $bind_param = $token_data->{'loginid'};
            }
            $dbic->run(
                ping => sub {
                    $_->do($sql, undef, $bind_param);
                });
        }
    }

    return;
}

sub is_pending_backfill {
    return BOM::MyAffiliates::BackfillManager->new->is_backfill_pending;
}

sub force_backfill {
    my $self    = shift;
    my $retries = 5;

    return 1 unless $self->is_pending_backfill;

    foreach (1 .. $retries) {
        BOM::MyAffiliates::BackfillManager->new->backfill_promo_codes;
        return 1 unless $self->is_pending_backfill;
        warn("[Attempt $_ of $retries] Backfill failed.");
        $self->_force_backfill_sleep;
    }

    return;
}

sub _force_backfill_sleep {
    sleep 60;
    return;
}

sub activity {
    my $self = shift;

    die('Backfill is pending and attempting to run it failed.') unless $self->force_backfill;

    my @result = $self->report();
    $self->register_tokens;

    return @result;
}

sub output_file_prefix {
    return 'registrations_';
}

sub headers {
    return HEADERS;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
