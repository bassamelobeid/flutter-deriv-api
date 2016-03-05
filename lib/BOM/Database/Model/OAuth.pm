package BOM::Database::Model::OAuth;

use Moose;
use Date::Utility;
use String::Random ();
use Try::Tiny;
use List::MoreUtils qw(uniq);
use BOM::Database::AuthDB;

has 'dbh' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbh {
    return BOM::Database::AuthDB::rose_db->dbh;
}

sub __parse_array {
    my ($array_string) = @_;
    return $array_string if ref($array_string) eq 'ARRAY';
    return [] unless $array_string;
    return BOM::Database::AuthDB::rose_db->parse_array($array_string);
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

    my $app = $self->dbh->selectrow_hashref("
        SELECT id, name, redirect_uri, scopes FROM oauth.apps WHERE id = ? AND active
    ", undef, $app_id);
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub confirm_scope {
    my ($self, $app_id, $loginid, @scopes) = @_;

    my $dbh = $self->dbh;

    my ($is_exists, $exists_scopes) = $dbh->selectrow_array("
        SELECT true, scopes FROM oauth.user_scope_confirm WHERE app_id = ? AND loginid = ?
    ", undef, $app_id, $loginid);
    if ($is_exists) {
        $exists_scopes = __parse_array($exists_scopes);
        push @scopes, @$exists_scopes;
        @scopes = __filter_valid_scopes(uniq @scopes);
        $dbh->do("
            UPDATE oauth.user_scope_confirm SET scopes = ? WHERE app_id = ? AND loginid = ?
        ", undef, \@scopes, $app_id, $loginid);
    } else {
        $dbh->do("INSERT INTO oauth.user_scope_confirm (app_id, loginid, scopes) VALUES (?, ?, ?)",
            undef, $app_id, $loginid, [__filter_valid_scopes(@scopes)]);
    }

    return 1;
}

sub is_scope_confirmed {
    my ($self, $app_id, $loginid, @scopes) = @_;

    my $dbh = $self->dbh;

    my ($confirmed_scopes) = $dbh->selectrow_array("
        SELECT scopes FROM oauth.user_scope_confirm WHERE app_id = ? AND loginid = ?
    ", undef, $app_id, $loginid);
    $confirmed_scopes = __parse_array($confirmed_scopes);

    foreach my $scope (@scopes) {
        return 0 unless grep { $_ eq $scope } @$confirmed_scopes;
    }

    return 1;
}

## store auth code
sub store_auth_code {
    my ($self, $app_id, $loginid, @scopes) = @_;

    my $dbh          = $self->dbh;
    my $auth_code    = String::Random::random_regex('[a-zA-Z0-9]{32}');
    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + 600)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max
    $dbh->do("
        INSERT INTO oauth.auth_code (auth_code, app_id, loginid, expires, scopes, verified)
        VALUES (?, ?, ?, ?, ?, false)
    ", undef, $auth_code, $app_id, $loginid, $expires_time, [__filter_valid_scopes(@scopes)]);

    return $auth_code;
}

## validate auth code
sub verify_auth_code {
    my ($self, $app_id, $auth_code) = @_;

    my $dbh = $self->dbh;

    my $auth_row = $dbh->selectrow_hashref("
        SELECT * FROM oauth.auth_code WHERE auth_code = ? AND app_id = ? AND NOT verified
    ", undef, $auth_code, $app_id);

    return unless $auth_row;
    return unless Date::Utility->new->is_before(Date::Utility->new($auth_row->{expires}));

    # set verified to avoid code-reuse
    $dbh->do("UPDATE oauth.auth_code SET verified=true WHERE auth_code = ?", undef, $auth_code);

    return $auth_row->{loginid};
}

sub get_scopes_by_auth_code {
    my ($self, $auth_code) = @_;

    my $sth = $self->dbh->prepare("SELECT scopes FROM oauth.auth_code WHERE auth_code = ?");
    $sth->execute($auth_code);
    my $scopes = $sth->fetchrow_array;
    $scopes = __parse_array($scopes);
    return @$scopes;
}

## store access token
sub store_access_token {
    my ($self, $app_id, $loginid, @scopes) = @_;

    my $dbh           = $self->dbh;
    my $expires_in    = 3600;
    my $access_token  = 'a1-' . String::Random::random_regex('[a-zA-Z0-9]{29}');
    my $refresh_token = 'r1-' . String::Random::random_regex('[a-zA-Z0-9]{29}');
    my $expires_time  = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max

    @scopes = __filter_valid_scopes(@scopes);

    $dbh->begin_work;
    try {
        $dbh->do("INSERT INTO oauth.access_token (access_token, app_id, loginid, scopes, expires) VALUES (?, ?, ?, ?, ?)",
            undef, $access_token, $app_id, $loginid, \@scopes, $expires_time);

        $dbh->do("INSERT INTO oauth.refresh_token (refresh_token, app_id, loginid, scopes) VALUES (?, ?, ?, ?)",
            undef, $refresh_token, $app_id, $loginid, \@scopes);

        $dbh->commit;
    }
    catch {
        $dbh->rollback;
    };

    return ($access_token, $refresh_token, $expires_in);
}

sub store_access_token_only {
    my ($self, $app_id, $loginid, @scopes) = @_;

    my $dbh          = $self->dbh;
    my $expires_in   = 86400;                                                     # for one day
    my $access_token = 'a1-' . String::Random::random_regex('[a-zA-Z0-9]{29}');

    @scopes = __filter_valid_scopes(@scopes);

    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max
    $dbh->do("INSERT INTO oauth.access_token (access_token, app_id, loginid, scopes, expires) VALUES (?, ?, ?, ?, ?)",
        undef, $access_token, $app_id, $loginid, \@scopes, $expires_time);

    return ($access_token, $expires_in);
}

sub get_loginid_by_access_token {
    my ($self, $token) = @_;

    return $self->dbh->selectrow_array("UPDATE oauth.access_token SET last_used=NOW() WHERE access_token = ? AND expires > NOW() RETURNING loginid",
        undef, $token);
}

sub get_scopes_by_access_token {
    my ($self, $access_token) = @_;

    my $sth = $self->dbh->prepare("
        SELECT scopes FROM oauth.access_token
        WHERE access_token = ?
    ");
    $sth->execute($access_token);
    my $scopes = $sth->fetchrow_array;
    $scopes = __parse_array($scopes);
    return @$scopes;
}

sub verify_refresh_token {
    my ($self, $app_id, $refresh_token) = @_;

    my $dbh = $self->dbh;

    my ($loginid) = $dbh->selectrow_array("
        SELECT loginid FROM oauth.refresh_token WHERE refresh_token = ? AND app_id = ? AND NOT revoked
    ", undef, $refresh_token, $app_id);
    return unless $loginid;

    # set revoked to avoid code-reuse
    $dbh->do("UPDATE oauth.refresh_token SET revoked=true WHERE refresh_token = ?", undef, $refresh_token);

    return $loginid;
}

sub get_scopes_by_refresh_token {
    my ($self, $refresh_token) = @_;

    my $sth = $self->dbh->prepare("SELECT scopes FROM oauth.refresh_token WHERE refresh_token = ?");
    $sth->execute($refresh_token);
    my $scopes = $sth->fetchrow_array;
    $scopes = __parse_array($scopes);
    return @$scopes;
}

sub is_name_taken {
    my ($self, $user_id, $name) = @_;

    return $self->dbh->selectrow_array("SELECT 1 FROM oauth.apps WHERE binary_user_id = ? AND name = ?", undef, $user_id, $name);
}

sub create_app {
    my ($self, $app) = @_;

    my $id = $app->{id} || 'id-' . String::Random::random_regex('[a-zA-Z0-9]{29}');

    my $sth = $self->dbh->prepare("
        INSERT INTO oauth.apps
            (id, name, scopes, homepage, github, appstore, googleplay, redirect_uri, binary_user_id)
        VALUES
            (? ,?, ?, ?, ?, ?, ?, ?, ?)
    ");
    $sth->execute(
        $id,
        $app->{name},
        $app->{scopes},
        $app->{homepage}     || '',
        $app->{github}       || '',
        $app->{appstore}     || '',
        $app->{googleplay}   || '',
        $app->{redirect_uri} || '',
        $app->{user_id});

    return {
        app_id       => $id,
        name         => $app->{name},
        scopes       => $app->{scopes},
        redirect_uri => $app->{redirect_uri},
    };
}

sub get_app {
    my ($self, $user_id, $app_id) = @_;

    my $app = $self->dbh->selectrow_hashref("
        SELECT id as app_id, name, redirect_uri, scopes FROM oauth.apps WHERE id = ? AND binary_user_id = ? AND active
    ", undef, $app_id, $user_id);
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub get_apps_by_user_id {
    my ($self, $user_id) = @_;

    my $apps = $self->dbh->selectall_arrayref("
        SELECT
            id as app_id, name, redirect_uri, scopes
        FROM oauth.apps WHERE binary_user_id = ? AND active ORDER BY name
    ", {Slice => {}}, $user_id);
    return [] unless $apps;

    foreach (@$apps) {
        $_->{scopes} = __parse_array($_->{scopes});
    }

    return $apps;
}

sub delete_app {
    my ($self, $user_id, $app_id) = @_;

    my $app = $self->get_app($user_id, $app_id);
    return 0 unless $app;

    my $dbh = $self->dbh;

    ## delete real delete
    foreach my $table ('user_scope_confirm', 'auth_code', 'access_token', 'refresh_token') {
        $dbh->do("DELETE FROM oauth.$table WHERE app_id = ?", undef, $app_id);
    }

    $dbh->do("DELETE FROM oauth.apps WHERE id = ?", undef, $app_id);

    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
