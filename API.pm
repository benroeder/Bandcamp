package Plugins::Bandcamp::API;

use strict;
use Encode;
use JSON::XS::VersionOneAndTwo;
use URI::Escape;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use constant API_URL_ALBUM => 'http://api.bandcamp.com/api/album/2/info';
use constant API_URL_BAND  => 'http://api.bandcamp.com/api/band/3/';
use constant API_URL_TRACK => 'http://api.bandcamp.com/api/track/1/info';
use constant API_URL_URL   => 'http://api.bandcamp.com/api/url/1/info';
use constant API_URL_SALES => 'http://bandcamp.com/cb_homepage_feed';
use constant CACHE_TTL     => 3600 * 12;
use constant META_CACHE_TTL=> 86400 * 30;

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
	
	main::DEBUGLOG && $log->debug("Searching for artists: $search");
	
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
	
	main::DEBUGLOG && $log->debug("Getting albums for artist: $band_id");
	
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
	
	main::DEBUGLOG && $log->debug("Getting information for url: $url");
	
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
	
	main::DEBUGLOG && $log->debug("Getting tracks for album: $album_id");
	
	_get( 
		sub {
			my $items = shift;

			# keep track information in the cache
			foreach my $track (@{$items->{tracks}}) {
				cache_track_info($items, $args);
			}
			
			$cb->($items) if $cb;
		}, 
		$params, 
		{
			_url     => API_URL_ALBUM,
			album_id => $album_id,
		}
	);
}

sub get_track_info {
	my ($args, $cb) = @_;
	
	my $track_id = $args->{track_id};
	
	main::DEBUGLOG && $log->debug("Getting track info for: $track_id");
	
	_get(
		sub {
			my $items = shift;

			$items = cache_track_info($items, $args);
			$cb->($items) if $cb;
		}, 
		undef, 
		{
			_url     => API_URL_TRACK,
			track_id => $track_id,
		}
	);
}

sub get_sales_feed {
	my ($client, $cb, $params) = @_;
	
	main::DEBUGLOG && $log->debug("Getting sales feed");
	
	if (my $cached = $cache->get('sales_feed_' . $client->id)) {
		main::DEBUGLOG && $log->debug('found cached api response' . Data::Dump::dump($cached));
		$cb->($cached) if $cb;
		return;
	}
	
	_get(
		sub {
			my $items = shift;

			my @albums;
			foreach my $event (@{$items->{events}}) {
				next unless $event->{event_type} && $event->{event_type} eq 'sale';
				
				foreach ( @{$event->{items}} ) {
					# we only want albums and tracks
					next unless $_->{item_type} && $_->{item_type} =~ /^[at]$/;
					
					my $meta = {
						artist => $_->{artist_name},
						title  => $_->{item_description},
						small_art_url => $_->{art_url},
						url    => $_->{band_url} . ($_->{item_slug} || $_->{album_slug}),
					};
					
					if ($_->{item_type} eq 't') {
						get_item_info_by_url($client,
							sub {
								my ($items) = shift;
			
								if ($items->{track_id}) {
									get_track_info($items);
								}
							}, 
							$params,
							$meta,
						);
					}

					$meta->{url} = $_->{band_url} . ($_->{album_slug} || $_->{item_slug});
					
					push @albums, $meta;
				}
			}
			
			# only cache responses for for a short period, as data is changing often
			$cache->set('sales_feed_' . $client->id, \@albums, 300);

			$cb->(\@albums) if $cb;
		}, 
		undef, 
		{
			_url       => API_URL_SALES,
			_nocache   => 1,		# sales update every minute
			_nokey     => 1,
			start_date => time() - 600,
		}
	);
}

sub cache_track_info {
	my ($track, $album) = @_;
	
	if (my $url = $track->{streaming_url}) {
		# use album information to complete track information if available
		if ($album) {
			$track->{artist} ||= $album->{artist};
			$track->{album}  ||= $album->{title};
			$track->{image}  ||= $track->{large_art_url} || $album->{large_art_url} || $album->{small_art_url};
			$track->{album_url} ||= $album->{url};
		}
			
		# complete with cached values if needed
		if ( my $cached = $cache->get('meta_' . $url) ) {
			foreach (keys %$cached) {
				$track->{$_} ||= $cached->{$_}; 
			}
		}
			
		# xxx - track api is broken, returning relative URLs; get domain name from album url
		if ($track->{url} && $track->{url} =~ m|^/| && $track->{album_url}) {
			my ($prefix) = $track->{album_url} =~ m|(http://.*?)/|;
	
			$track->{url} = $prefix . $track->{url};
		}

		$cache->set('meta_' . $url, $track, META_CACHE_TTL);
	}
	
	return $track;
}

sub _get {
	my ( $cb, $params, $args ) = @_;
	
	my $url = (delete $args->{_url}) . ($args->{_nokey} ? '?' : '?key=' . $dk);
		
	for my $k ( keys %{$args} ) {
		next if $k =~ /^_/;
		$url .= '&' . $k . '=' . URI::Escape::uri_escape_utf8( Encode::decode( 'utf8', $args->{$k} ) );
	}

	main::DEBUGLOG && $log->debug($url);
	
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
				elsif (!$args->{_nocache}) {
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

1;