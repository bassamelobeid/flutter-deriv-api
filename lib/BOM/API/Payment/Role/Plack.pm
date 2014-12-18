package BOM::API::Payment::Role::Plack;

use Moo::Role;
use Plack::Request;
use Scalar::Util qw( looks_like_number );
use Data::Dumper;
use XML::Simple;

has 'env' => (
    is       => 'ro',
    required => 1
);
has 'req' => (is => 'lazy');

sub _build_req {
    Plack::Request->new((shift)->env);
}

# alias
sub request { (shift)->req }

has 'user' => (is => 'lazy');

sub _build_user {
    return (shift)->env->{BOM_USER};
}

has 'request_parameters' => (
    is          => 'lazy',
);

sub _build_request_parameters {
    my $c = shift;

    my $content_type = $c->req->header('Content-Type');
    my $params  = $c->req->parameters;

    if (keys %{$params}) {
        return $params;
    } elsif ($content_type and $content_type =~ 'xml') {
        my $xs = XML::Simple->new(ForceArray => 0);
        if ($c->req->content) {
            return $xs->XMLin($c->req->content);
        }
    }

    return;
}

## Response
sub throw {
    my $c       = shift;
    my $log     = $c->env->{log};
    my $status  = shift || 500;
    my $message = shift || do {
        $log->error("Raising Status $status, no message");
        return { status_code => $status };
    };
    chomp($message);
    $log->error(sprintf '%s: %s', $c->user||'(no-user)', $message);
    return {
        status_code => $status,
        error       => $message
    }
}

sub status_bad_request {
    my ($c, $message) = @_;
    my $log = $c->env->{log};
    chomp($message);
    $log->warn(sprintf '%s: %s', $c->user||'(no-user)', $message);
    return {
        status_code => 400,
        error       => $message
    };
}

sub status_created {
    my ($c, $location) = @_;

    return $c->req->new_response(201, [Location => $location]);
}

## Validator
sub validate {
    my ($c, @required_fields) = @_;

    foreach my $f (@required_fields) {
        return "$f is required." unless defined $c->request_parameters->{$f};
    }

    if (my $currency_code = $c->request_parameters->{'currency_code'}) {
        my @currencies = qw(AUD EUR GBP USD);
        my $regex = '(' . join('|', @currencies) . ')';
        return "Invalid currency $currency_code. Must be one of: " . join(', ', @currencies)
          unless $currency_code =~ /^$regex$/;
    }

    foreach my $f ('trace_id', 'reference_number') {
        next unless my $v = $c->request_parameters->{$f};
        return "$f must be a positive integer." unless $v =~ /^\d+$/ and $v > 0;
    }

    # subtype 'bom_money', as Num, where { not /\.\d{3}/ and not /\.$/ }, message { "Invalid money amount $_" };
    foreach my $f ('amount', 'bonus', 'fee') {
        next unless defined(my $v = $c->request_parameters->{$f});
        return "Invalid money amount: $v" unless looks_like_number($v);
        return "Invalid money amount: $v" if $v =~ /\.\d{3}/ or $v =~ /\.$/;

        # extra validate for amount
        if ($f eq 'amount') {
            return "Invalid money amount: $v" unless $v >= 0.01 and $v <= 100000;
        }
    }

    return;
}

no Moo::Role;
1;
