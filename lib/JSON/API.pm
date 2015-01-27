package JSON::API;
use strict;
use LWP::UserAgent;
use JSON;
use Data::Dumper;

BEGIN {
	use Exporter ();
	use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
	$VERSION     = '1.0.6';
	@ISA         = qw(Exporter);
	#Give a hoot don't pollute, do not export more than needed by default
	@EXPORT      = qw();
	@EXPORT_OK   = qw();
	%EXPORT_TAGS = ();
}

sub _debug
{
	my ($self, @lines) = @_;
	my $output = join('\n', @lines);
	print STDERR $output . "\n" if ($self->{debug});
}

sub _server
{
	my ($self, $input) = @_;
	$input =~ s|^(https?://)?||;
	$input =~ m|^([^\s:/]+)(:\d+)?.*|;
	$input = $1 . ($2 || '');
	return $input;
}

sub _http_req
{
	my ($self, $method, $path, $data) = @_;
	$self->_debug('_http_req called with the following:',Dumper($method,$path,$data));

	my $url = $self->url($path);
	$self->_debug("URL calculated to be: $url");

	my $headers = HTTP::Headers->new(
			'Accept'       => 'application/json',
			'Content-Type' => 'application/json',
	);

	my $json;
	if (defined $data) {
		$json = $self->_encode($data);
		return (wantarray ? (500, {}) : {}) unless defined $json;
	}

	my $req = HTTP::Request->new($method, $url, $headers, $json);
	$self->_debug("Requesting: ",Dumper($req));
	my $res = $self->{user_agent}->request($req);

	$self->_debug("Response: ",Dumper($res));
	if ($res->is_success) {
		$self->{has_error}    = 0;
		$self->{error_string} = '';
		$self->_debug("Successful request detected");
	} else {
		$self->{has_error} = 1;
		$self->{error_string} = $res->content;
		$self->_debug("Error detected: ".$self->{error_string});
		# If internal warning, return before decoding, as it will fail + overwrite the error_string
		if ($res->header('client-warning') =~ m/internal response/i) {
			return wantarray ? ($res->code, {}) : {};
		}
	}
	my $decoded = $res->content ? ($self->_decode($res->content) || {}) : {};

	#FIXME: should we auto-populate an error key in the {} if error detected but no content?
	return wantarray ?
			($res->code, $decoded) :
			$decoded;
}

sub _encode
{
	my ($self, $obj) = @_;

	my $json = undef;
	eval {
		$json = to_json($obj);
		$self->_debug("JSON created: $json");
	} or do {
		if ($@) {
			$self->{has_error} = 1;
			$self->{error_string} = $@;
			$self->{error_string} =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*//;
			$self->_debug("Error serializing json from \$obj:" . $self->{error_string});
		}
	};
	return $json;
}

sub _decode
{
	my ($self, $json) = @_;

	$self->_debug("Deserializing JSON");
	my $obj = undef;
	eval {
		$obj = from_json($json);
		$self->_debug("Deserializing successful:",Dumper($obj));
	} or do {
		if ($@) {
			$self->{has_error} = 1;
			$self->{error_string} = $@;
			$self->{error_string} =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*//;
			$self->_debug("Error deserializing: ".$self->{error_string});
		}
	};
	return $obj;
}

sub new
{
	my ($class, $base_url, %parameters) = @_;
	return undef unless $base_url;

	my %ua_opts = %parameters;
	map { delete $parameters{$_}; } qw(user pass realm debug);

	my $ua = LWP::UserAgent->new(%parameters);

	my $self = bless ({
				base_url     => $base_url,
				user_agent   => $ua,
				has_error    => 0,
				error_string => '',
				debug        => $ua_opts{debug},
		}, ref ($class) || $class);

	my $server = $self->_server($base_url);
	my $default_port = $base_url =~ m|^https://| ? 443 : 80;
	$server .= ":$default_port" unless $server =~ /:\d+$/;
	$ua->credentials($server, $ua_opts{realm}, $ua_opts{user}, $ua_opts{pass})
		if ($ua_opts{realm} && $ua_opts{user} && $ua_opts{pass});

	return $self;
}

sub get
{
	my ($self, $path) = @_;
	$self->_http_req("GET", $path);
}

sub put
{
	my ($self, $path, $data) = @_;
	$self->_http_req("PUT", $path, $data);
}

sub post
{
	my ($self, $path, $data) = @_;
	$self->_http_req("POST", $path, $data);
}

sub del
{
	my ($self, $path) = @_;
	$self->_http_req("DELETE", $path);
}

sub url
{
	my ($self, $path) = @_;
	my $url = $self->{base_url} . "/$path";
	# REGEX-FU: look through the URL, replace any matches of /+ with '/',
	# as long as the previous character was not a ':'
	# (e.g. http://example.com//api//mypath/ becomes http://example.com/api/mypath/
	$url =~ s|(?<!:)/+|/|g;
	return $url;
}

sub errstr
{
	my ($self) = @_;
	return ! $self->was_success ? $self->{error_string} : '';
}

sub was_success
{
	my ($self) = @_;
	return $self->{has_error} ? 0 : 1;
}

1;

=head1 NAME

JSON::API - Module to interact with a JSON API

=head1 SYNOPSIS

  use JSON::API;
  my $api = JSON::API->new("http://myapp.com/");
  my $obj = { name => 'foo', type => 'bar' };
  if ($api->put("/add/obj", $obj) {
    print "Success!\n";
  } else {
    print $api->errstr . "\n";
  }

=head1 DESCRIPTION

This module wraps JSON and LWP::UserAgent to create a flexible utility
for accessing APIs that accept/provide JSON data.

It supports all the options LWP supports, including authentication.

=head1 METHODS

=head2 new

Creates a new JSON::API object for connecting to any API that accepts
and provide JSON data.

Example:

	my $api = JSON::API->new("https://myapp.com:8443/path/to/app",
		user => 'foo',
		pass => 'bar',
		realm => 'my_protected_site',
		agent => 'MySpecialBrowser/1.0',
		cookie_jar => '/tmp/cookie_jar',
	);

Parameters:

=over

=item base_url

The base URL to apply to all requests you send this api, for example:

https://myapp.com:8443/path/to/app

=item parameters

This is a hash of options that can be passed in to an LWP object.
Additionally, the B<user>, B<pass>, and B<realm> may be provided
to configure authentication for LWP. You must provide all three parameters
for authentication to work properly.

Specifying debug => 1 in the parameters hash will also enable debugging output
within JSON::API.

=back

=head2 get|post|put|del

Perform an HTTP action (GET|POST|PUT|DELETE) against the given API. All methods
take the B<path> to the API endpoint as the first parameter. The B<put()> and
B<post()> methods also accept a second B<data> parameter, which should be a reference
to be serialized into JSON for POST/PUTing to the endpoint.

If called in scalar context, returns the deserialized JSON content returned by
the server. If no content was returned, returns an empty hashref. To check for errors,
call B<errstr> or B<was_success>.

If called in list context, returns a two-value array. The first value will be the
HTTP response code for the request. The second value will either be the deserialized
JSON data. If no data is returned, returns an empty hashref.

=head2 get

Performs an HTTP GET on the given B<path>. B<path> will be appended to the
B<base_url> provided when creating this object.

  my $obj = $api->get('/objects/1');

See get|post|put|del for details.

=head2 put

Performs an HTTP PUT on the given B<path>, with the provided B<data>. Like
B<get>, this will append path to the end of the B<base_url>.

  $api->put('/objects/', $obj);

See get|post|put|del for details.

=head2 post

Performs an HTTP POST on the given B<path>, with the provided B<data>. Like
B<get>, this will append path to the end of the B<base_url>.

  $api->post('/objects/', [$obj1, $obj2]);

See get|post|put|del for details.

=head2 del

Performs an HTTP DELETE on the given B<path>. Like B<get>, this will append
path to the end of the B<base_url>.

  $api->del('/objects/first');

See get|post|put|del for details.

=head2 errstr

Returns the current error string for the last call.

=head2 was_success

Returns whether or not the last request was successful.

=head2 url

Returns the complete URL of a request, when given a path.

=cut

=head1 REPOSITORY

L<https://github.com/geofffranks/json-api>

=head1 AUTHOR

    Geoff Franks <gfranks@cpan.org>

=head1 COPYRIGHT

Copyright 2014, Geoff Franks

This library is licensed under the GNU General Public License 3.0

