package Plugins::Bandcamp::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Bandcamp::API;
use Plugins::Bandcamp::Scraper;

#my $prefs = preferences('plugin.bandcamp');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.bandcamp',
	defaultLevel => 'DEBUG',
	description  => 'PLUGIN_BANDCAMP',
} );

use constant PLUGIN_TAG => 'bandcamp';

sub initPlugin {
	my $class = shift;
	
	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => PLUGIN_TAG,
		menu   => 'my_apps',
		is_app => 1,
		weight => 1,
	);
}

sub getDisplayName { 'PLUGIN_BANDCAMP' }

# this ensures the menu is in the radio menu on some player types
sub playerMenu { 'MY_APPS' }


sub handleFeed {
	my ($client, $cb, $params, $args) = @_;
	
	my $p = $params->{params};
	
	if (my $search = $p->{q}) {
		Plugins::Bandcamp::API::search_artists($client, $cb, $params, $search);
	}
#	elsif (my $artist = $q->param('artist')) {
#		$items = get_artist_albums($artist);
#	}
#	elsif (my $album = $q->param('albumtracks')) {
#		$items = get_album_tracks($album);
#	}
	elsif ($args->{tags}) {
		Plugins::Bandcamp::Scraper::get_tags($client, $cb, $params);
	}
	elsif ($args->{locations}) {
		Plugins::Bandcamp::Scraper::get_locations($client, $cb, $params);
	}
	else {
		$cb->({
			items => [
				{
					name => cstring($client, 'SEARCH'),
					type => 'search',
					url  => \&handleFeed,
					passthrough => [ { q => '{QUERY}' } ]
				},
				{
					name => cstring($client, 'PLUGIN_BANDCAMP_TAGS'),
					type => 'link',
					url  => \&handleFeed,
					passthrough => [ { tags => 1 } ],
				},
				{
					name => cstring($client, 'PLUGIN_BANDCAMP_LOCATIONS'),
					type => 'link',
					url  => \&handleFeed,
					passthrough => [ { locations => 1 } ]
				}
			],
		});
	}
}


1;