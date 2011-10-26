package Plugins::Bandcamp::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use JSON::XS::VersionOneAndTwo;
use Storable;

use Slim::Formats::RemoteMetadata;
use Slim::Menu::GlobalSearch;
use Slim::Menu::TrackInfo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Bandcamp::API;
use Plugins::Bandcamp::Scraper;
use Plugins::Bandcamp::Search;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.bandcamp',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_BANDCAMP',
} );

use constant PLUGIN_TAG => 'bandcamp';
use constant STREAM_URL_REGEX => qr/bandcamp\.com\/download\/track/i;

my $cache = Slim::Utils::Cache->new;

sub initPlugin {
	my $class = shift;

	Plugins::Bandcamp::API::init( $class->_pluginDataFor('dk') );	
	
	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => PLUGIN_TAG,
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
	
	Slim::Formats::RemoteMetadata->registerProvider(
		match => STREAM_URL_REGEX,
		func  => \&metadata_provider,
	);
	
	# Track Info item
	Slim::Menu::TrackInfo->registerInfoProvider( bandcamp => (
		after => 'moreinfo',
		func  => \&trackInfoMenu,
	) );
	
	Slim::Menu::GlobalSearch->registerInfoProvider( bandcamp => (
		before => 'middle',
		func   => sub {
			my ( $client, $tags ) = @_;
			
			my $searchParam = $tags->{search};
			my $passthrough = [{ q => $searchParam }];

			return [{
				name  => cstring($client, 'PLUGIN_BANDCAMP'),
				items => [{
					name        => cstring($client, 'SEARCHFOR_ARTISTS'),
					url         => \&Plugins::Bandcamp::Search::search_artists,
					passthrough => $passthrough,
					searchParam => $searchParam,
				},{
					name        => cstring($client, 'PLUGIN_BANDCAMP_SEARCHFOR_TAGS'),
					url         => \&Plugins::Bandcamp::Search::search_tags,
					passthrough => $passthrough,
					searchParam => $searchParam,
				}]
			}]
		},
	) );		
}

sub getDisplayName { 'PLUGIN_BANDCAMP' }

# don't add this plugin to the Extras menu
sub playerMenu {}


sub handleFeed {
	my ($client, $cb, $args) = @_;
	
	my $params = $args->{params};
	
	$cb->({
		items => [
			{
				name  => cstring($client, 'SEARCH'),
				type => 'search',
				url  => \&Plugins::Bandcamp::Search::search
			},
			{
				name => cstring($client, 'PLUGIN_BANDCAMP_TAGS'),
				type => 'link',
				url  => \&Plugins::Bandcamp::Scraper::get_tags,
			},
			{
				name => cstring($client, 'PLUGIN_BANDCAMP_LOCATIONS'),
				type => 'link',
				url  => \&Plugins::Bandcamp::Scraper::get_locations,
			},
			{
				name => cstring($client, 'RECENT_SEARCHES'),
				type => 'link',
				url  => \&Plugins::Bandcamp::Search::recent_searches,
			}
		],
	});
}

# helper methods for metadata and trackinfo

sub metadata_provider {
	my ( $client, $url ) = @_;

	my $meta = {
		title => Slim::Music::Info::getCurrentTitle(shift),
		cover  => __PACKAGE__->_pluginDataFor('icon'),
	};
	
	if (my $cached = $cache->get('plugin_bandcamp_meta_' . $url)) {
		$cached->{album_url} =~ s/\?pk=.*// if $cached->{album_url};
		
		$meta = {
			title    => $cached->{title},
			artist   => $cached->{album} . ($cached->{album} ? ' - ' : '') . $cached->{artist},
			# we'll abuse the album name for the album URL to satisfy the terms of use...
			album    => $cached->{album_url},
			duration => $cached->{duration},
			cover    => $cached->{image},
#			bitrate  => '128k CBR',
#			type     => 'MP3 (bandcamp.com)',
#			icon     => __PACKAGE__->getIcon(),
		};
#	warn Data::Dump::dump($cached);
	}
	
#	warn Data::Dump::dump($meta);
	
	return $meta;
}

sub trackInfoMenu {
	my ( $client, undef, $track ) = @_;
	
	return unless $client && $track;
	
	my $url = $track->url;
	
	return unless $url && $url =~ STREAM_URL_REGEX;

	if (my $cached = $cache->get('plugin_bandcamp_meta_' . $url)) {
		$cached->{large_art_url} = $cached->{image};
		$cached->{notracks}      = 1;
		
		return {
			type => 'link',
			name => cstring($client, 'PLUGIN_FROM_BANDCAMP'),
			url  => \&Plugins::Bandcamp::API::get_track_info,
			passthrough => [ $cached ],
		};
	}
	
	return;
}


# methods creating the lists to be shown from our data
sub artist_list {
	my $items = shift;
	
	return [ {
		name => $items->{error},
		type => 'text',
	} ] if $items->{error};
	
	my $artists = [];
	foreach (@{$items->{results}}) {
		push @$artists, {
			name  => $_->{name},
			line1 => $_->{offsite_url} ? $_->{name} : undef,
			line2 => $_->{offsite_url} || undef,
			url   => \&Plugins::Bandcamp::API::get_artist_albums,
			passthrough => [{
				band_id => $_->{band_id},
			}],
			type  => 'link',
		}
	}
	
	return $artists;
}

sub tag_album_list {
	my $items = shift;
	
	return [ {
		name => $items->{error},
		type => 'text',
	} ] if $items->{error};
	
	my $albums = [];
	foreach (@{$items->{results}}) {
		push @$albums, {
			name  => $_->{album} . ($_->{artist} ? ' - ' . $_->{artist} : ''),
			line1 => $_->{artist} ? $_->{album} : undef,
			line2 => $_->{artist},
			url   => \&Plugins::Bandcamp::API::get_item_info_by_url,
			image => $_->{image},
			passthrough => [{
				url    => $_->{url},
				artist => $_->{artist},
				image  => $_->{image},
				tracks => 1,
			}],
			type  => 'playlist',
		};
	}

	return $albums;
}


# caching helpers
sub set_cache {
	my ($k, $v, $t) = @_;
	$cache->set('plugin_bandcamp_recent_' . $k, $v, $t || 86400);
}

sub get_cache {
	my ($k) = @_;
	return $cache->get('plugin_bandcamp_recent_' . $k);
}

1;