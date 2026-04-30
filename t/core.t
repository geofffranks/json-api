use strict;
use utf8;
use IO::Capture::Stderr;
use Test::More;
use JSON::API;


{ # test regular URL
	my $api = JSON::API->new('http://myserver.com/');
	is($api->url('/api//path/'), 'http://myserver.com/api/path/', 'url() for basename with http://');
}

{ # test w/out http://
	my $api = JSON::API->new('myserver.com/');
	is($api->url('/api'), 'myserver.com/api', 'url() for basename without http://');
}

{ # test with https://
	my $api = JSON::API->new('https://myserver.com/');
	is($api->url('/api'), 'https://myserver.com/api', 'url() for basename with https://');
}

{ # test with :8080
	my $api = JSON::API->new('http://myserver.com:8080/');
	is($api->url('/api'), 'http://myserver.com:8080/api', 'url() for basename with :portnum');
}

{ # test json deserializing with valid json
	my $json = '{"name":"foo","value":"bar"}';
	my $api = JSON::API->new('test');
	is_deeply($api->_decode($json), {name =>'foo',value=>'bar'},
		'Good JSON returns hashref on decode');
}

{ # test json deserializing with invalid json
	my $json = 'blahblah{"';
	my $api = JSON::API->new('test');
	is_deeply($api->_decode($json), undef, 'Bad JSON returns undef on decode');
	like($api->errstr,
		qr/^malformed JSON string, neither /,
		'Bad JSON sets proper errstr'
	);
}


{ # test json serializing with valid obj
	my $obj = { name => 'foo' };
	my $api = JSON::API->new('test');
	is($api->_encode($obj), '{"name":"foo"}', 'Valid object gets serialized to JSON');
}

{ # arrayref also accepted by _encode
	my $arr = [ { name => 'foo' }, { name => 'bar' } ];
	my $api = JSON::API->new('test');
	is($api->_encode($arr),
		'[{"name":"foo"},{"name":"bar"}]',
		'arrayref serializes to JSON array');
}

{ # test json serializing with invalid obj
	my $obj = 'asdf';
	my $api = JSON::API->new('test');
	is_deeply($api->_encode($obj), undef, 'Invalid object sent for serialization returns undef');
	is($api->errstr,
		'hash- or arrayref expected (not a simple scalar, use allow_nonref to allow this)',
		'Bad encode sets proper errstr'
	);
}

{ # Issue #10: _encode produces UTF-8 bytes for non-ASCII payloads
	# (HTTP::Request requires bytes; without ->utf8, JSON->encode returns
	# a Unicode string which HTTP::Message rejects: "content must be bytes")
	my $obj = { name => "snowman \x{2603}" };
	my $api = JSON::API->new('test');
	my $json = $api->_encode($obj);
	ok(defined $json, '_encode of non-ASCII obj is defined');
	ok(!utf8::is_utf8($json),
		'_encode returns byte string (utf8 flag clear) for non-ASCII');
	is($json, '{"name":"snowman ' . "\xe2\x98\x83" . '"}',
		'_encode emits UTF-8 octets for snowman codepoint');
}

{ # Issue #10: _decode handles UTF-8 bytes from server into Unicode
	my $bytes = '{"name":"snowman ' . "\xe2\x98\x83" . '"}';
	my $api = JSON::API->new('test');
	my $obj = $api->_decode($bytes);
	is($obj->{name}, "snowman \x{2603}",
		'_decode parses UTF-8 byte input into Unicode codepoint');
}

{ # Issue #3: _encode strips Perl's "<FH> line/chunk N" suffix from errstr
	# Perl appends ", <FH> line N" (or "chunk N") when <> was active
	package JSON::API::Test::EncodeFH; ## no critic (Modules::RequireFilenameMatchesPackage)
	sub encode { die "boom at -e line 1, <STDIN> line 1.\n" }
	package main;

	my $api = JSON::API->new('test');
	$api->{_json} = bless {}, 'JSON::API::Test::EncodeFH';
	is($api->_encode({}), undef, '_encode returns undef on encode failure');
	is($api->errstr, 'boom',
		'_encode strips both " at FILE line N" and trailing ", <FH> line N" suffix');
}

{ # Issue #3: _encode strips multi-line carp trace from errstr
	package JSON::API::Test::EncodeCarp; ## no critic (Modules::RequireFilenameMatchesPackage)
	sub encode { die "boom at -e line 1.\n\teval {...} called at -e line 1\n" }
	package main;

	my $api = JSON::API->new('test');
	$api->{_json} = bless {}, 'JSON::API::Test::EncodeCarp';
	is($api->_encode({}), undef, '_encode returns undef on encode failure');
	is($api->errstr, 'boom',
		'_encode strips multi-line carp trace beyond first "at FILE line N"');
}

{ # Issue #3: _decode strips Perl's "<FH> line/chunk N" suffix from errstr
	package JSON::API::Test::DecodeFH; ## no critic (Modules::RequireFilenameMatchesPackage)
	sub decode { die "boom at -e line 1, <STDIN> line 1.\n" }
	package main;

	my $api = JSON::API->new('test');
	$api->{_json} = bless {}, 'JSON::API::Test::DecodeFH';
	is($api->_decode('{}'), undef, '_decode returns undef on decode failure');
	is($api->errstr, 'boom',
		'_decode strips both " at FILE line N" and trailing ", <FH> line N" suffix');
}

{ # Issue #3: _decode strips multi-line carp trace from errstr
	package JSON::API::Test::DecodeCarp; ## no critic (Modules::RequireFilenameMatchesPackage)
	sub decode { die "boom at -e line 1.\n\teval {...} called at -e line 1\n" }
	package main;

	my $api = JSON::API->new('test');
	$api->{_json} = bless {}, 'JSON::API::Test::DecodeCarp';
	is($api->_decode('{}'), undef, '_decode returns undef on decode failure');
	is($api->errstr, 'boom',
		'_decode strips multi-line carp trace beyond first "at FILE line N"');
}

{ # test _debug prints to stderr
	my $capture = IO::Capture::Stderr->new();
	$capture->start;
	my $api = JSON::API->new('test', debug => 1);
	$api->_debug("my debug message");
	$capture->stop;
	is($capture->read, "my debug message\n", '_debug prints to STDERR when debug is set.');
}

{ # test _debug prints to stderr
	my $capture = IO::Capture::Stderr->new();
	$capture->start;
	my $api = JSON::API->new('test');
	$api->_debug("my debug message");
	$capture->stop;
	is($capture->read, undef, '_debug doesnt print to STDERR when debug is not set.');
}

{ # errstr
	my $api = JSON::API->new('test');
	$api->{error_string} = 'my test error';
	is($api->errstr, '', '$api->errstr returns empty string when no error present');
	$api->{has_error} = 1;
	is($api->errstr, 'my test error', '$api->errstr returns empty string when no error present');
}

{ # test server generation
	my $server = JSON::API->new('test')->_server('http://myhost.com:80');
	is($server, 'myhost.com:80', 'http://myhost.com:80 server is myhost.com:80');

	$server = JSON::API->new('test')->_server('http://myhost.com/');
	is($server, 'myhost.com', 'http://myhost.com/ server is myhost.com');

	$server = JSON::API->new('test')->_server('https://myhost.com:80');
	is($server, 'myhost.com:80', 'https://myhost.com:80 server is myhost.com:80');

	$server = JSON::API->new('test')->_server('https://myhost.com/');
	is($server, 'myhost.com', 'https://myhost.com/ server is myhost.com');

	$server = JSON::API->new('test')->_server('myhost.com:80');
	is($server, 'myhost.com:80', 'myhost.com:80 server is myhost.com:80');

	$server = JSON::API->new('test')->_server('myhost.com/');
	is($server, 'myhost.com', 'myhost.com/ server is myhost.com');

	$server = JSON::API->new('test')->_server('myhost.com:80/asdf');
	is($server, 'myhost.com:80', 'myhost.com:80/asdf server is myhost.com:80');

	$server = JSON::API->new('test')->_server('myhost.com/asdf/');
	is($server, 'myhost.com', 'myhost.com/asdf/ server is myhost.com');
}

{ # test was_success
	my $api = JSON::API->new('test');
	$api->{has_error} = 0;
	is($api->was_success, 1, "absence of has_error = success");

	$api->{has_error} = 1;
	is($api->was_success, 0, "presence of has_error = fail");
}

{ # predecodehook: strips CSRF-prefix garbage before JSON decode
	my $api = JSON::API->new('test',
		predecodehook => sub {
			my $j = shift;
			$j =~ s/^\)\]\}',?\n//;
			$j;
		});
	my $payload = ")]}',\n" . '{"name":"foo"}';
	is_deeply($api->_decode($payload), { name => 'foo' },
		'predecodehook runs before decode and produces a parseable payload');
}

{ # client-warning: Internal response short-circuits decode
	package JSON::API::Test::InternalWarnUA; ## no critic (Modules::RequireFilenameMatchesPackage)
	sub new { bless {}, shift }
	sub request {
		require HTTP::Response;
		return HTTP::Response->new(500, 'failed',
			[ 'client-warning' => 'Internal response' ],
			'connect: Connection refused');
	}
	sub credentials { }
	package main;

	my $api = JSON::API->new('http://unreachable.invalid/');
	$api->{user_agent} = JSON::API::Test::InternalWarnUA->new;
	my ($code, $body) = $api->get('/x');
	is($code, 500,
		'client-warning Internal response surfaces upstream code');
	is_deeply($body, {},
		'client-warning Internal response returns empty hashref + skips decode');
	ok(!$api->was_success,
		'client-warning Internal response leaves has_error set');

	my $scalar = $api->get('/x');
	is_deeply($scalar, {},
		'client-warning Internal response returns empty hashref in scalar context');
}

{ # header() / response() are safe to call before any request
	my $api = JSON::API->new('http://x.example/');
	is($api->response, undef,
		'response() returns undef when no request has been made');
	is($api->header('ETag'), undef,
		'header($name) returns undef when no response is cached');
	is_deeply([ $api->header ], [],
		'header() with no arg returns empty list when no response is cached');
}

{ # new() called as instance method blesses into the same class
	my $a = JSON::API->new('http://a.example/');
	my $b = $a->new('http://b.example/');
	isa_ok($b, 'JSON::API', 'instance->new() returns blessed JSON::API');
	is($b->url('x'), 'http://b.example/x',
		'instance->new() uses the new base_url, not the parent');
}

done_testing;
