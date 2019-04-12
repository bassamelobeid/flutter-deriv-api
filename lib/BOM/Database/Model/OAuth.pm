package BOM::Database::Model::OAuth;

use Moose;
use Date::Utility;
use Try::Tiny;
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

    my $app = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("
        SELECT id, name, redirect_uri, scopes, app_markup_percentage, bypass_verification FROM oauth.apps WHERE id = ? AND active
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
    delete @$result{qw(binary_user_id stamp id bypass_verification)};
    return $result;
}

sub update_app {
    my ($self, $app_id, $app) = @_;

    # get old scopes
    my $old_scopes = $self->dbic->run(
        ping => sub {
            my $sth = $_->prepare("SELECT scopes FROM oauth.apps WHERE id = ?");
            $sth->execute($app_id);
            my $old_scopes = $sth->fetchrow_array;
            return __parse_array($old_scopes);
        });
    return if !@$old_scopes;

    my $updated_app = $self->dbic->run(
        ping => sub {
            my $sth = $_->prepare("
        UPDATE oauth.apps SET
            name = ?, scopes = ?, homepage = ?, github = ?,
            appstore = ?, googleplay = ?, redirect_uri = ?, verification_uri = ?, app_markup_percentage = ?, active = ?
        WHERE id = ?
        RETURNING *
    ");
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
                $app->{active} // 1,
                $app_id
            );
            my $result = $sth->fetchrow_hashref();
            return $result;
        });

    ## revoke user_scope_confirm on scope changes
    if ($old_scopes
        and join('-', sort @$old_scopes) ne join('-', sort @{$app->{scopes}}))
    {
        foreach my $table ('user_scope_confirm', 'access_token') {
            $self->dbic->run(fixup => sub { $_->do("DELETE FROM oauth.$table WHERE app_id = ?", undef, $app_id) });
        }
    }

    $updated_app->{scopes} = __parse_array($updated_app->{scopes});
    $updated_app->{app_id} = $updated_app->{id};
    delete @$updated_app{qw(binary_user_id stamp id bypass_verification)};

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

sub delete_app {
    my ($self, $user_id, $app_id) = @_;

    my $app = $self->get_app($user_id, $app_id);
    return 0 unless $app;

    my $dbic = $self->dbic;

    $dbic->run(
        ping => sub {
            ## delete real delete
            foreach my $table ('user_scope_confirm', 'access_token') {
                $_->do("DELETE FROM oauth.$table WHERE app_id = ?", undef, $app_id);
            }
            $_->do("DELETE FROM oauth.apps WHERE id = ?", undef, $app_id);
        });
    return 1;
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
    my ($self, $app_id) = @_;
    my $app = $self->get_app_by_id($app_id);
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
