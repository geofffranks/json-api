use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
	module_name         => 'JSON::API',
	license             => 'bsd',
	dist_author         => q{Geoff Franks <geoff.franks@gmail.com>},
	dist_version_from   => 'lib/JSON/API.pm',

	configure_requires => {
		'Module::Build' => '0.38',
	},

	add_to_cleanup => [
		'JSON-API-*',
		'cover_db',
		'*.rpm',
		'*.deb',
	]
);

$builder->create_build_script();
