package BOM::Platform::SessionCookie;
use Data::Random::String;
use BOM::System::Chronicle;
use JSON;

sub new {
    my ($package, $self) = shift;
    if ($self->{token}) {
        $self = JSON::from_json(BOM::System::Chronicle->_redis_read->get('LOGIN_SESSIN::'.$self->{token})) || {};  
    } else {
        $self->{token} = Data::Random::String->create_random_string(length=>'128');
        BOM::System::Chronicle->_redis_write->set('LOGIN_SESSIN::'.$self->{token},JSON::to_json($self));
    }
    BOM::System::Chronicle->_redis_write->ttl('LOGIN_SESSIN::'.$self->{token}, 3600 * 24);       
    return bless $self, $package;
}

sub session_data {
    my ($class, $token) = @_;
    BOM::System::Chronicle->_redis_read->get($token);
}

sub validate_session {
    my $self = shift;
    my $scope = shift;
    return unless $self->{token};
    return not $scope or grep { $_ eq $scope } @{$self->{scopes}}
}

sub end_session {
    my $self = shift;
    BOM::System::Chronicle->_redis_write->set('LOGIN_SESSIN::'.$self->{token});
}
1;
