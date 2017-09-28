package BOM::MyAffiliates::GenerateRegistrationDaily;

use Moose;
use Text::CSV;
use Text::Trim;
use Path::Tiny;
use FileHandle;

use Date::Utility;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::CollectorReporting;
use BOM::Platform::Runtime;
use BOM::MyAffiliates::BackfillManager;
use LandingCompany;

has start_time => (
    is       => 'ro',
    default  => sub { Date::Utility->new },
    init_arg => undef
);

has input_date => (
    is      => 'rw',
    default => sub { Date::Utility->new(time - 86400)->date_ddmmmyy; },
);

has requested_date => (
    is      => 'ro',
    isa     => 'Date::Utility',
    lazy    => 1,
    default => sub { Date::Utility->new({datetime => shift->input_date}) },
);

has date_to => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_date_to {
    my $self = shift;
    return Date::Utility->new({datetime => $self->requested_date->date_ddmmmyy . ' 23:59:59GMT'})->datetime_yyyymmdd_hhmmss;
}

has filepath => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_filepath {
    return BOM::Platform::Runtime->instance->app_config->system->directory->db . '/myaffiliates/';
}

has filename => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_filename {
    my $self = shift;
    return $self->filepath . 'registrations_' . $self->requested_date->date_yyyymmdd . '.csv';
}

has _fh => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build__fh {
    my $self = shift;
    $self->_create_filepath;
    return FileHandle->new('>>' . $self->filename);
}

sub _create_filepath {
    my $self = shift;
    Path::Tiny::path($self->filepath)->mkpath if (not -d $self->filepath);
    return;
}

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
    my $candidates = $report_mapper->get_unregistered_client_token_pairs_before_datetime($self->date_to);
    return $candidates;
}

sub any_new_clients {
    my $self = shift;
    return scalar $self->new_clients;
}

sub create_report {
    my $self = shift;

    die("Report already exists? ", $self->filename) if (-e $self->filename);

    print {$self->_fh} $self->report;
    return;
}

sub report {
    my $self = shift;

    return 0 unless $self->any_new_clients;

    my $csv = Text::CSV->new;
    return join "\n", map {
        $csv->combine($self->_date_joined($_), $_->{loginid}, $_->{myaffiliates_token});
        trim($csv->string);
    } @{$self->new_clients};
}

sub _date_joined {
    my ($self, $client_data) = @_;
    my $date_joined = $client_data->{date_joined};

    if (!$date_joined) {
        warn("date_joined is empty?! [", $client_data->{'loginid'}, "]: [$date_joined]");
        $date_joined = $self->start_time->date_yyyymmdd;
    }
    return Date::Utility->new({datetime => $date_joined})->date_yyyymmdd;
}

has registered_tokens => (
    is       => 'rw',
    lazy     => 1,
    init_arg => undef,
    default  => undef
);

sub register_tokens {
    my $self = shift;

    my @overall_results;
    foreach my $broker (LandingCompany::Registry::all_broker_codes) {
        next if ($broker eq 'FOG');

        my @matched_tokens = grep { $_->{'loginid'} =~ /^$broker/ } @{$self->new_clients};
        my @results_for_broker;

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
                sub {
                    $_->do($sql, undef, $bind_param);
                });
            push @results_for_broker,
                  $token_data->{'date_joined'} . ' '
                . $token_data->{'loginid'} . ' '
                . ' creative['
                . $token_data->{'is_creative'} . '] '
                . $token_data->{'myaffiliates_token'};
        }

        if (scalar @results_for_broker) {
            push @overall_results, @results_for_broker;
        }
    }

    $self->registered_tokens(\@overall_results);
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

sub run {
    my $self = shift;
    die('Backfill is pending and attempting to run it failed.') unless $self->force_backfill;
    $self->create_report;
    $self->register_tokens;

    my @full_report = ('Registration Report:', '', 'Effective Date    LoginID     Creative?    Token');
    push @full_report, @{$self->registered_tokens};
    return {
        start_time => $self->start_time,
        report     => \@full_report
    };
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
