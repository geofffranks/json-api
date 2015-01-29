use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
	module_name         => 'JSON::API',
	license             => 'gpl_3',
	dist_author         => q{Geoff Franks <geoff.franks@gmail.com>},
	dist_version_from   => 'lib/JSON/API.pm',
	meta_merge => {
		resources => {
			repository => 'https://github.com/dwimperl/Task-DWIM',
		},
	},

	configure_requires => {
		'Module::Build' => '0.38',
	},
	requires => {
		'JSON'           => 0,
		'LWP::UserAgent' => 0,
		'URI::Encode'    => 0,
	},
	build_requires => {
		'JSON' => 0,
		'Test::Fake::HTTPD'   => 0,
		'IO::Capture'         => 0,
		'LWP::UserAgent'      => 0,
		'Test::More'          => 0,
		'Test::Pod::Coverage' => 0,

	},

	add_to_cleanup => [
		'JSON-API-*',
		'cover_db',
		'*.rpm',
		'*.deb',
	]
);

$builder->create_build_script();
