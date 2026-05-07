use strict;
use warnings;
use Module::Build;

# Subclass to add a `./Build critic` action that runs Perl::Critic
# against lib/ and t/ at the project's --gentle severity. Same check
# as the author-mode test in t/author-perlcritic.t -- this just lets
# you invoke it standalone without running the full test suite.
my $class = Module::Build->subclass(
	class => 'JSON::API::Builder',
	code => <<'CRITIC_ACTION',
sub ACTION_critic {
	my $self = shift;
	require Test::Perl::Critic;
	Test::Perl::Critic->import(-severity => 'gentle');
	Test::Perl::Critic::all_critic_ok('lib', 't');
}
CRITIC_ACTION
);

my $builder = $class->new(
	module_name         => 'JSON::API',
	create_license      => 1,
	license             => 'perl',
	dist_author         => q{Geoff Franks <geoff.franks@gmail.com>},
	dist_version_from   => 'lib/JSON/API.pm',
	meta_merge => {
		resources => {
			homepage   => 'https://github.com/geofffranks/json-api',
			bugtracker => 'https://github.com/geofffranks/json-api/issues',
			repository => 'git://github.com/geofffranks/json-api.git',
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
