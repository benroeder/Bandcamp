package Plugins::Bandcamp::API;

use strict;
use Encode;
use JSON::XS::VersionOneAndTwo;
use URI::Escape;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

use constant API_URL_ALBUM => 'http://api.bandcamp.com/api/album/2/info';
use constant API_URL_BAND  => 'http://api.bandcamp.com/api/band/3/';
use constant API_URL_TRACK => 'http://api.bandcamp.com/api/track/1/info';
use constant API_URL_URL   => 'http://api.bandcamp.com/api/url/1/info';
use constant CACHE_TTL     => 3600 * 12;

my $log = logger('plugin.bandcamp');

my ($dk, $cache);

sub init {
	($cache, $dk) = @_;
	$dk =~ s/-//g;
}

sub search_artists {
	my ($client, $cb, $args) = @_;
	
	my $search = $args->{search};
	my $params = $args->{params};
	
	$log->debug("Searching for artists: $search");
	
	_get( 
		$cb,
		$params, 
		{
			_url => API_URL_BAND . 'search',
			name => $search,
		}
	);
}


sub get_artist_albums {
	my ($client, $cb, $params, $args) = @_;
	
	my $band_id = $args->{band_id};
	
	$log->debug("Getting albums for artist: $band_id");
	
	_get(
		$cb, 
		$params, 
		{
			_url    => API_URL_BAND . 'discography',
			band_id => $band_id,
		}
	);
}

sub get_item_info_by_url {
	my ($client, $cb, $params, $args) = @_;
	
	my $url = $args->{url};
	
	$log->debug("Getting information for url: $url");
	
	_get(
		$cb, 
		$params, 
		{
			_url   => API_URL_URL,
			url    => $url,
		}
	);
}

sub get_album_info {
	my ($client, $cb, $params, $args) = @_;
	
	my $album_id = $args->{album_id};
	
	$log->debug("Getting tracks for album: $album_id");
	
	_get( 
		$cb,
		$params, 
		{
			_url     => API_URL_ALBUM,
			album_id => $album_id,
		}
	);
}


# helper method to pre-cache all information related to a track 
# unfortunately the track/info call would only return IDs for album
# and artist, thus we have to do a bunch of calls for every track...
sub fetch_all_track_info {
	my ($track_id) = @_;
	
	$log->debug("Getting complete track info for: $track_id");
	
	_get( 
		sub {
			my $items = shift;

			# for each track call the artist information and album information...
			foreach ( @{ $items } ) {
				
			}

		}, 
#		$params, 
		{
			_url     => API_URL_TRACK,
			track_id => $track_id,
		}
	);
}

sub get_track_info {
	my ($client, $cb, $params, $args) = @_;
	
	my $track_id = $args->{track_id};
	
	$log->debug("Getting track info for: $track_id");
	
	_get(
		$cb, 
		$params, 
		{
			_url     => API_URL_TRACK,
			track_id => $track_id,
		}
	);
}

sub _get {
	my ( $cb, $params, $args ) = @_;
	
	my $url = (delete $args->{_url}) . '?key=' . $dk;
		
	for my $k ( keys %{$args} ) {
		$url .= '&' . $k . '=' . URI::Escape::uri_escape_utf8( Encode::decode( 'utf8', $args->{$k} ) );
	}

	$log->debug($url);
	
	if (my $cached = $cache->get('api_' . $url)) {
		main::DEBUGLOG && $log->debug('found cached api response' . Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}
	
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			
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
				else {
					$cache->set('api_' . $url, $result, CACHE_TTL);
				}
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
			timeout => 30,
		},
	)->get($url);
}

sub _cleanup {
	my $text = shift;
	
	$text =~ s/\r\n/\n/g;
	
	return $text;
}

1;