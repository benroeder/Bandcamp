package Plugins::Bandcamp::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use JSON::XS::VersionOneAndTwo;
use Storable;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Bandcamp::API;
use Plugins::Bandcamp::Scraper;

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
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
	
	Slim::Formats::RemoteMetadata->registerProvider(
		match => qr/bandcamp\.com\/download\/track/i,
		func  => \&metadata_provider,
	);

	Plugins::Bandcamp::API::init( $class->_pluginDataFor('dk') );	
}

sub getDisplayName { 'PLUGIN_BANDCAMP' }

# this ensures the menu is in the radio menu on some player types
sub playerMenu { 'MY_APPS' }


sub handleFeed {
	my ($client, $cb, $args) = @_;
	
	my $params = $args->{params};
	
	$cb->({
		items => [
			{
				name  => cstring($client, 'SEARCH'),
				type => 'search',
				url  => \&search
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
			}
		],
	});
}

my $search_results = {};
sub search {
	my ($client, $cb, $params, $search) = @_;
	
	$search_results->{$client || ''} = {};
	
	Plugins::Bandcamp::API::search_artists($client,
		sub {
			my $items = shift;
			$search_results->{$client || ''}->{'artist_search'} = $items;
			_search_done($client, $cb, $items);
		}, 
		$params, 
		$search
	);
	
	Plugins::Bandcamp::Scraper::search_tags($client,
		sub {
			my $items = shift;
			$search_results->{$client || ''}->{'tag_search'} = $items;
			_search_done($client, $cb, $items);
		}, 
		$params, 
		$search
	);
}

sub _search_done {
	my ($client, $cb, $items) = @_;
	
	return unless $search_results->{$client || ''}->{'tag_search'} && $search_results->{$client || ''}->{'artist_search'};

	my $items = [ 
		sort { uc($a->{name}) cmp uc($b->{name}) } 
			@{$search_results->{$client || ''}->{'tag_search'}->{items}}, 
			@{$search_results->{$client || ''}->{'artist_search'}->{items}} 
	];
	
	$items = [{
		name => cstring($client, 'EMPTY'),
		type => 'text',
	}] if !scalar @$items;
	
	$cb->( { 
		items => $items
	} );
}

my $cache = Slim::Utils::Cache->new;

sub metadata_provider {
	my ( $client, $url ) = @_;

	my $meta = {
		title => Slim::Music::Info::getCurrentTitle(shift),
		cover  => __PACKAGE__->_pluginDataFor('icon'),
	};
	
	if (my $cached = $cache->get($url)) {
		$meta = {
			title    => $cached->{title},
			artist   => $cached->{album} . ' - ' . $cached->{artist},
			# we'll abuse the album name for the album URL to satisfy the terms of use...
			album    => $cached->{album_url},
			duration => $cached->{duration},
			cover    => $cached->{image},
#			bitrate  => '128k CBR',
#			type     => 'MP3 (bandcamp.com)',
#			icon     => __PACKAGE__->getIcon(),
		} 
	}
	
	return $meta;
}

1;