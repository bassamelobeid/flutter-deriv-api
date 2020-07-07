package BOM::Database::Model::OAuth;

use Moose;
use Date::Utility;
use BOM::Database::AuthDB;

has 'dbic' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbic {
    return BOM::Database::AuthDB::rose_db()->dbic;
}

sub __parse_array {
    my ($array_string) = @_;
    return $array_string if ref($array_string) eq 'ARRAY';
    return [] unless $array_string;
    return BOM::Database::AuthDB::rose_db()->parse_array($array_string);
}

my @token_scopes = ('read', 'trade', 'payments', 'admin');
my %available_scopes = map { $_ => 1 } @token_scopes;

sub __filter_valid_scopes {
    my (@s) = @_;
    return grep { $available_scopes{$_} } @s;
}

## app
sub verify_app {
    my ($self, $app_id) = @_;

    return unless $app_id =~ /^[0-9]+$/ && $app_id < sprintf("%.0f", 2**63);    # upper range of Postgres BIGINT

    my $app = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("
        SELECT id, name, redirect_uri, scopes, app_markup_percentage, bypass_verification, secret, verification_uri FROM oauth.apps WHERE id = ? AND active
    ", undef, $app_id);
        });
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

=head2

Get Names by App ID

Takes in either an arrayref or a single integer and returns a hash of the ID(s) passed in and their respective names.

=cut

sub get_names_by_app_id {
    my ($self, $app_id) = @_;

    $app_id = [$app_id] unless ref $app_id eq 'ARRAY';
    # We may be called with a large number of duplicates by code that maps transactions to the app_id source. We filter those out here to reduce a tiny bit of database load and also keep debugging output more readable when tracing the SQL queries.
    $app_id = [List::Util::uniq(@$app_id)];

    my $app = $self->dbic->run(
        fixup => sub {
            $_->selectall_hashref("SELECT * FROM oauth.get_app_names(?)", "id", undef, $app_id);
        });

    $app = {map { $_ => $app->{$_}->{name} } keys %$app};

    return $app;
}

=head2 is_official_app

Checks if the app is among official

=over 4

=item * C<app_id> - application ID

=back

Returns true if the app is present in official_apps table

=cut

sub is_official_app {
    my ($self, $app_id) = @_;

    my ($is_official) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("SELECT EXISTS(SELECT 1 FROM oauth.official_apps WHERE app_id = ?)", undef, $app_id);
        });

    return $is_official ? 1 : 0;
}

=head2 is_primary_website

Checks if the app is among official apps and is a primary website.

=over 4

=item * C<app_id> - application ID

=back

Returns true if the app is official and primary.

=cut

sub is_primary_website {
    my ($self, $app_id) = @_;

    my ($is_primary_website) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("
        SELECT is_primary_website FROM oauth.official_apps WHERE app_id = ?
    ", undef, $app_id);
        });

    return $is_primary_website ? 1 : 0;
}

sub confirm_scope {
    my ($self, $app_id, $loginid) = @_;

    $self->dbic->run(
        ping => sub {
            $_->selectrow_array("
        SELECT true FROM oauth.user_scope_confirm WHERE app_id = ? AND loginid = ?
    ", undef, $app_id, $loginid)
                or $_->do("INSERT INTO oauth.user_scope_confirm (app_id, loginid) VALUES (?, ?)", undef, $app_id, $loginid);
        });
    return 1;
}

sub is_scope_confirmed {
    my ($self, $app_id, $loginid) = @_;

    my ($confirmed_scopes) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("
        SELECT true FROM oauth.user_scope_confirm WHERE app_id = ? AND loginid = ?
    ", undef, $app_id, $loginid);
        });

    return $confirmed_scopes ? 1 : 0;
}

sub store_access_token_only {
    my ($self, $app_id, $loginid, $ua_fingerprint) = @_;
    return $self->dbic->run(fixup =>
            sub { $_->selectrow_array("SELECT * FROM oauth.create_token(29, ?, ?, '60d'::INTERVAL, ?)", undef, $app_id, $loginid, $ua_fingerprint) });
}

sub get_token_details {
    my ($self, $token) = @_;

    my $expires_in = '60 days';

    my $details = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref(<<'SQL', undef, $token, $expires_in) });
SELECT loginid, creation_time, ua_fingerprint, scopes
  FROM oauth.get_token_details($1, $2::INTERVAL)
SQL
    $details->{scopes} = __parse_array($details->{scopes});

    return $details;
}

sub get_verification_uri_by_app_id {
    my ($self, $app_id) = @_;

    my ($verification_uri) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("
        SELECT verification_uri FROM oauth.apps WHERE id = ? AND active
    ", undef, $app_id);
        });

    return $verification_uri;
}

sub get_scopes_by_access_token {
    my ($self, $access_token) = @_;

    my $scopes = $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("
        SELECT app.scopes FROM oauth.access_token at
        JOIN oauth.apps app ON app.id=at.app_id
        WHERE access_token = ?
    ");
            $sth->execute($access_token);
            return $sth->fetchrow_array;
        });
    $scopes = __parse_array($scopes);
    return @$scopes;
}

sub is_name_taken {
    my ($self, $user_id, $name) = @_;

    return $self->dbic->run(
        fixup => sub { $_->selectrow_array("SELECT 1 FROM oauth.apps WHERE binary_user_id = ? AND name = ?", undef, $user_id, $name) });
}

sub create_app {
    my ($self, $app) = @_;

    my $result = $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("
        INSERT INTO oauth.apps
            (name, scopes, homepage, github, appstore, googleplay, redirect_uri, verification_uri, app_markup_percentage, binary_user_id)
        VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING * ");
            $sth->execute(
                $app->{name},
                $app->{scopes},
                $app->{homepage}              || '',
                $app->{github}                || '',
                $app->{appstore}              || '',
                $app->{googleplay}            || '',
                $app->{redirect_uri}          || '',
                $app->{verification_uri}      || '',
                $app->{app_markup_percentage} || 0,
                $app->{user_id});

            my $result = $sth->fetchrow_hashref();
            return $result;
        });
    $result->{scopes} = __parse_array($result->{scopes});
    $result->{app_id} = $result->{id};
    delete @$result{qw(binary_user_id stamp id bypass_verification secret)};
    return $result;
}

=head2 update_app


B<NOTE> update_app does: update application details by calling app_update function in auth database.

Function args:

=over 4

=item * C<app_id> - application ID "Int"

=item * C<app> - hash reference for application data.

=back

Returns a hash reference for the application updated data

=cut

sub update_app {
    my ($self, $app_id, $app) = @_;

    my $updated_app = $self->dbic->run(
        ping => sub {
            my $sth = $_->prepare("select * from oauth.app_update(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");

            $sth->execute(
                $app_id,                  $app->{name},                  $app->{scopes},     $app->{homepage},
                $app->{github},           $app->{appstore},              $app->{googleplay}, $app->{redirect_uri},
                $app->{verification_uri}, $app->{app_markup_percentage}, $app->{active});
            my $result = $sth->fetchrow_hashref();
            return $result;
        });
    $updated_app->{scopes} = __parse_array($updated_app->{scopes});
    return $updated_app;
}

sub get_app {
    my ($self, $user_id, $app_id, $active) = @_;
    $active = $active // 1;    #defined($active) ? $active : 1;
    my $app = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("
        SELECT
            id as app_id, name, redirect_uri, verification_uri, scopes,
            homepage, github, appstore, googleplay, app_markup_percentage, active
        FROM oauth.apps WHERE id = ? AND binary_user_id = ? AND active = ?", undef, $app_id, $user_id, $active);
        });
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub get_app_by_id {
    my ($self, $app_id) = @_;
    my $app = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT *  FROM oauth.apps WHERE id = ?", undef, $app_id);
        });

    return unless $app;
    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub get_apps_by_user_id {
    my ($self, $user_id) = @_;

    my $apps = $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("
        SELECT
            id as app_id, name, redirect_uri, verification_uri, scopes,
            homepage, github, appstore, googleplay, app_markup_percentage, active
        FROM oauth.apps WHERE binary_user_id = ? AND active ORDER BY name", {Slice => {}}, $user_id);
        });
    return [] unless $apps;

    foreach (@$apps) {
        $_->{scopes} = __parse_array($_->{scopes});
    }

    return $apps;
}

sub get_app_ids_by_user_id {
    my ($self, $user_id) = @_;

    my $app_ids = $self->dbic->run(
        fixup => sub {
            $_->selectcol_arrayref("
        SELECT
            id
        FROM oauth.apps WHERE binary_user_id = ?", undef, $user_id);
        });
    return $app_ids || [];
}

sub get_used_apps_by_loginid {
    my ($self, $loginid) = @_;

    return $self->dbic->run(
        fixup => sub {
            my $dbh  = $_;
            my $apps = $dbh->selectall_arrayref("
        SELECT
            u.app_id, a.name, a.scopes, a.app_markup_percentage,
            u.last_login as last_used
        FROM oauth.apps a JOIN oauth.user_scope_confirm u ON a.id=u.app_id
        WHERE u.loginid = ? AND a.active ORDER BY a.name
    ", {Slice => {}}, $loginid);
            return [] unless $apps;
            $_->{scopes} = __parse_array($_->{scopes}) for @$apps;
            return $apps;
        });

}

sub revoke_app {
    my ($self, $app_id, $loginid) = @_;

    my $dbic = $self->dbic;
    $dbic->run(
        ping => sub {
            foreach my $table ('user_scope_confirm', 'access_token') {
                $_->do("DELETE FROM oauth.$table WHERE app_id = ? AND loginid = ?", undef, $app_id, $loginid);
            }
        });
    return 1;
}

sub revoke_tokens_by_loginid {
    my ($self, $loginid) = @_;
    $self->dbic->run(
        ping => sub {
            $_->do("DELETE FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        });
    return 1;
}

sub revoke_tokens_by_loginid_app {
    my ($self, $loginid, $app_id) = @_;
    $self->dbic->run(
        ping => sub {
            $_->do("DELETE FROM oauth.access_token WHERE loginid = ? AND app_id = ?", undef, $loginid, $app_id);
        });
    return 1;
}

sub has_other_login_sessions {
    my ($self, $loginid) = @_;

    # "Binary.com backoffice" app has id = 4, we use it to create token for BO impersonate. So should be excluded here.
    my $login_cnt = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ? AND expires > now() AND app_id <> 4", undef, $loginid);
        });
    return ($login_cnt >= 1);
}

=head2 get_app_id_by_token

retrieve app_id from a given token

=over 4

=item * C<Token> I receives token to find app_id

=back

Returns app_id if it successfully found app_id and returns undef otherwise.

=cut

sub get_app_id_by_token {
    my ($self, $token) = @_;

    my @result =
        $self->dbic->run(fixup => sub { $_->selectrow_array("SELECT app_id FROM oauth.access_token WHERE access_token = ?", undef, $token) });
    return $result[0];
}

sub user_has_app_id {
    my ($self, $user_id, $app_id) = @_;

    return $self->dbic->run(
        fixup => sub { $_->selectrow_array("SELECT id FROM oauth.apps WHERE binary_user_id = ? AND id = ?", undef, $user_id, $app_id) });
}

sub block_app {
    my ($self, $app_id, $user_id) = @_;
    my $app = $self->get_app_by_id($app_id);
    return 0 unless $app;
    return 0 if ($user_id && $app->{binary_user_id} ne $user_id);
    $app->{active} = 0;
    return $self->update_app($app_id, $app);
}

sub unblock_app {
    my ($self, $app_id) = @_;
    my $app = $self->get_app_by_id($app_id);
    $app->{active} = 1;
    return $self->update_app($app_id, $app);
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
