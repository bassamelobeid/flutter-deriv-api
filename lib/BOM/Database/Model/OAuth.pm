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
    my ($self, $app_key) = @_;

    my $app = $self->dbh->selectrow_hashref("
        SELECT key, name, redirect_uri, scopes FROM oauth.apps WHERE key = ? AND active
    ", undef, $app_key);
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub confirm_scope {
    my ($self, $app_key, $loginid) = @_;

    my $dbh = $self->dbh;

    my ($is_exists, $exists_scopes) = $dbh->selectrow_array("
        SELECT true FROM oauth.user_scope_confirm WHERE app_key = ? AND loginid = ?
    ", undef, $app_key, $loginid);
    unless ($is_exists) {
        $dbh->do("INSERT INTO oauth.user_scope_confirm (app_key, loginid) VALUES (?, ?)", undef, $app_key, $loginid);
    }

    return 1;
}

sub is_scope_confirmed {
    my ($self, $app_key, $loginid) = @_;

    my ($confirmed_scopes) = $self->dbh->selectrow_array("
        SELECT true FROM oauth.user_scope_confirm WHERE app_key = ? AND loginid = ?
    ", undef, $app_key, $loginid);

    return $confirmed_scopes ? 1 : 0;
}

sub store_access_token_only {
    my ($self, $app_key, $loginid) = @_;

    my $dbh          = $self->dbh;
    my $expires_in   = 5184000;                                                   # 60 * 86400
    my $access_token = 'a1-' . String::Random::random_regex('[a-zA-Z0-9]{29}');

    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;
    $dbh->do("INSERT INTO oauth.access_token (access_token, app_key, loginid, expires) VALUES (?, ?, ?, ?)",
        undef, $access_token, $app_key, $loginid, $expires_time);

    return ($access_token, $expires_in);
}

sub get_loginid_by_access_token {
    my ($self, $token) = @_;

    ## extends access token expires 60 days
    my $expires_in = 5184000;
    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;

    return $self->dbh->selectrow_array("
        UPDATE oauth.access_token
        SET last_used=NOW(), expires=?
        WHERE access_token = ? AND expires > NOW()
        RETURNING loginid, creation_time
    ", undef, $expires_time, $token);
}

sub get_scopes_by_access_token {
    my ($self, $access_token) = @_;

    my $sth = $self->dbh->prepare("
        SELECT app.scopes FROM oauth.access_token at
        JOIN oauth.apps app ON app.key=at.app_key
        WHERE access_token = ?
    ");
    $sth->execute($access_token);
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

    my $key = $app->{key} || 'id-' . String::Random::random_regex('[a-zA-Z0-9]{29}');

    my $sth = $self->dbh->prepare("
        INSERT INTO oauth.apps
            (key, name, scopes, homepage, github, appstore, googleplay, redirect_uri, binary_user_id)
        VALUES
            (? ,?, ?, ?, ?, ?, ?, ?, ?)
    ");
    $sth->execute(
        $key,
        $app->{name},
        $app->{scopes},
        $app->{homepage}     || '',
        $app->{github}       || '',
        $app->{appstore}     || '',
        $app->{googleplay}   || '',
        $app->{redirect_uri} || '',
        $app->{user_id});

    return {
        app_key      => $key,
        name         => $app->{name},
        scopes       => $app->{scopes},
        redirect_uri => $app->{redirect_uri},
    };
}

sub get_app {
    my ($self, $user_id, $app_key) = @_;

    my $app = $self->dbh->selectrow_hashref("
        SELECT key as app_key, name, redirect_uri, scopes FROM oauth.apps WHERE key = ? AND binary_user_id = ? AND active
    ", undef, $app_key, $user_id);
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub get_apps_by_user_id {
    my ($self, $user_id) = @_;

    my $apps = $self->dbh->selectall_arrayref("
        SELECT
            key as app_key, name, redirect_uri, scopes
        FROM oauth.apps WHERE binary_user_id = ? AND active ORDER BY name
    ", {Slice => {}}, $user_id);
    return [] unless $apps;

    foreach (@$apps) {
        $_->{scopes} = __parse_array($_->{scopes});
    }

    return $apps;
}

sub delete_app {
    my ($self, $user_id, $app_key) = @_;

    my $app = $self->get_app($user_id, $app_key);
    return 0 unless $app;

    my $dbh = $self->dbh;

    ## delete real delete
    foreach my $table ('user_scope_confirm', 'access_token') {
        $dbh->do("DELETE FROM oauth.$table WHERE app_key = ?", undef, $app_key);
    }

    $dbh->do("DELETE FROM oauth.apps WHERE key = ?", undef, $app_key);

    return 1;
}

sub get_used_apps_by_loginid {
    my ($self, $loginid) = @_;

    my $apps = $self->dbh->selectall_arrayref("
        SELECT
            u.app_key, name, a.scopes
        FROM oauth.apps a JOIN oauth.user_scope_confirm u ON a.key=u.app_key
        WHERE loginid = ? AND a.active ORDER BY a.name
    ", {Slice => {}}, $loginid);
    return [] unless $apps;

    my $get_last_used_sth = $self->dbh->prepare("
        SELECT MAX(last_used)::timestamp(0) FROM oauth.access_token WHERE app_key = ?
    ");

    foreach (@$apps) {
        $_->{scopes} = __parse_array($_->{scopes});
        $get_last_used_sth->execute($_->{app_key});
        $_->{last_used} = $get_last_used_sth->fetchrow_array;
    }

    return $apps;
}

sub revoke_app {
    my ($self, $app_key, $loginid) = @_;

    my $dbh = $self->dbh;
    foreach my $table ('user_scope_confirm', 'access_token') {
        $dbh->do("DELETE FROM oauth.$table WHERE app_key = ? AND loginid = ?", undef, $app_key, $loginid);
    }

    return 1;
}

sub revoke_tokens_by_loginid {
    my ($self, $loginid) = @_;
    $self->dbh->do("DELETE FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
    return 1;
}

sub revoke_tokens_by_loginid_app {
    my ($self, $loginid, $app_key) = @_;
    $self->dbh->do("DELETE FROM oauth.access_token WHERE loginid = ? AND app_key = ?", undef, $loginid, $app_key);
    return 1;
}

sub get_app_key_by_token {
    my ($self, $token) = @_;

    my $dbh = $self->dbh;
    my @result = $self->dbh->selectrow_array("SELECT app_key FROM oauth.access_token WHERE access_token = ?", undef, $token);
    return $result[0];
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
