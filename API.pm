package Plugins::Bandcamp::API;

use strict;
use Encode;
use JSON::XS::VersionOneAndTwo;
use URI::Escape;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);

use constant API_KEY       => 'perladruslasaemingserligr';
use constant API_URL_ALBUM => 'http://api.bandcamp.com/api/album/2/';
use constant API_URL_BAND  => 'http://api.bandcamp.com/api/band/3/';
use constant API_URL_TRACK => 'http://api.bandcamp.com/api/track/1/';
use constant API_URL_URL   => 'http://api.bandcamp.com/api/url/1/';
use constant CACHE_TTL     => 3600;


my $log = logger('plugin.bandcamp');

sub search_artists {
	my ($client, $cb, $args) = @_;
	
	my $search = $args->{search};
	my $params = $args->{params};
	
	$log->debug("Searching for artists: $search");
	
	_get($client, 
		sub {
			my $items = shift;
			$cb->( {
				items => _artist_list($items)
			}, @_ );
		}, 
		$params, 
		{
			url  => API_URL_BAND . 'search',
			name => $search,
		}
	);
}

sub _artist_list {
	my $items = shift;
	
	return [ {
		name => $items->{error},
		type => 'text',
	} ] if $items->{error};
	
	my $artists = [];
	foreach my $artist (@{$items->{results}}) {
		push @$artists, {
			name  => $artist->{name},
			line1 => $artist->{offsite_url} ? $artist->{name} : undef,
			line2 => $artist->{offsite_url} || undef,
			url   => \&get_artist_albums,
			passthrough => [{
				band_id => $artist->{band_id},
			}],
			type  => 'link',
		}
	}
	
	return $artists;
}

sub get_artist_albums {
	my ($client, $cb, $params, $args) = @_;
	
	my $band_id = $args->{band_id};
	
	$log->debug("Getting albums for artist: $band_id");
	
	_get($client, 
		sub {
			my $items = shift;
			$cb->( {
				items => _album_list($items)
			}, @_ );
		}, 
		$params, 
		{
			url     => API_URL_BAND . 'discography',
			band_id => $band_id,
		}
	);
}

sub _album_list {
	my $items = shift;
	
	return [ {
		name => $items->{error},
		type => 'text',
	} ] if $items->{error};
	
	my $albums = [];
	foreach my $album (@{$items->{discography}}) {
		push @$albums, {
			type  => 'playlist',
			name  => $album->{title} . ($album->{artist} ? ' - ' . $album->{artist} : ''),
			line1 => $album->{artist} ? $album->{album} : undef,
			line2 => $album->{artist},
			url   => \&get_album_info,
			image => $album->{large_art_url},
			passthrough => [{ 
				album_id  => $album->{album_id},
				album_url => $album->{url},
				band_id   => $album->{band_id},
				tracks    => 1,
			}],
		};
	}
	
	return $albums;
}

sub get_album_info {
	my ($client, $cb, $params, $args) = @_;
	
	my $album_id   = $args->{album_id};
	my $get_tracks = $args->{tracks};
	
	$log->debug("Getting tracks for album: $album_id");
	
	_get($client, 
		sub {
			my $albumInfo = shift;
			
			return [ {
				name => $albumInfo->{error},
				type => 'text',
			} ] if $albumInfo->{error};
	
			my $items = [
				{
					name => $albumInfo->{title},
					type => 'text'
				},
				{
					name => (
						cstring($client, $albumInfo->{downloadable} 
							? ($albumInfo->{downloadable} = 1 ? 'PLUGIN_BANDCAMP_FREE' : 'PLUGIN_BANDCAMP_PAID')
							: 'PLUGIN_BANDCAMP_NO_DOWNLOAD'
						)
					),
					type => 'text',
				},
				{
					name => $albumInfo->{url},
					type => 'text'
				},
			];

			push @$items, {
				name => cstring($client, 'PLUGIN_BANDCAMP_ABOUT'),
				items => [{
					name => $albumInfo->{about},
					type => 'text',
					wrap => 1,
				}]
			} if $albumInfo->{about};
			
			push @$items, {
				name => cstring($client, 'PLUGIN_BANDCAMP_CREDITS'),
				items => [{
					name => $albumInfo->{credits},
					type => 'text',
					wrap => 1,
				}]
			} if $albumInfo->{credits};
			
			if ($get_tracks) {
				push @$items, @{ _track_list($albumInfo->{tracks}) };
			}
			
			$cb->( $items, @_ );
		}, 
		$params, 
		{
			url      => API_URL_ALBUM . 'info',
			album_id => $album_id,
		}
	);
}

sub _track_list {
	my $items = shift;
	
	my $tracks = [];
	foreach my $track (@{$items}) {
		push @$tracks, {
			type  => 'audio',
			name  => $track->{title},
			url   => $track->{streaming_url},
			image => $track->{large_art_url},
		};
	}
	
	return $tracks;
}

sub _get {
	my ( $client, $cb, $params, $args ) = @_;
	
	my $url = (delete $args->{url}) . '?key=' . API_KEY;
		
	for my $k ( keys %{$args} ) {
		$url .= '&' . $k . '=' . URI::Escape::uri_escape_utf8( Encode::decode( 'utf8', $args->{$k} ) );
	}

	$log->debug($url);
	
	my $cache = Slim::Utils::Cache->new;
	if (my $cached = $cache->get('plugin_bandcamp_api_' . $url)) {
		$log->debug('found cached api response');
		$cb->($cached);
		return;
	}
	
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			my $client   = $params->{client};
			
			my $result;
			
			if ( $response->headers->content_type =~ /json/ ) {
				$result = decode_json(
					$response->content,
				);
				
				main::DEBUGLOG && $log->debug(Data::Dump::dump($result));
				
				if ( !$result || $result->{error} ) {
					$result = {
						error => 'Error: ' . ($result->{error_message} || 'Unknown error')
					};
					$log->error($result->{error});
				}
				
				$cache->set('plugin_bandcamp_api_' . $url, $result, CACHE_TTL);
			}
			else {
				$log->error("Invalid data");
				$result = { 
					error => 'Error: Invalid data',
				};
			}
			$cb->($result);
		},
		sub {
			$log->warn("error: $_[1]");
			$cb->([ { 
				name => 'Unknown error: ' . $_[1],
				type => 'text' 
			} ]);
		},
		{
			params  => $params,
			client  => $client,
			timeout => 30,
		},
	)->get($url);
}



1;