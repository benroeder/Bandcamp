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
		sub {
			my $items = shift;
			$cb->( {
				items => _album_list($items)
			}, @_ );
		}, 
		$params, 
		{
			_url    => API_URL_BAND . 'discography',
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
			url   => $album->{album_id} ? \&get_album_info : \&get_track_info,
			image => $album->{large_art_url},
			passthrough => [{ 
				album_id  => $album->{album_id},
				album_url => $album->{url},
				band_id   => $album->{band_id},
				artist    => $album->{artist},
				track_id  => $album->{track_id},
				large_art_url => $album->{large_art_url},
				tracks    => 1,
			}],
		};
	}

	return [ {
		name => string('EMPTY'),
		type => 'text',
	} ] if !scalar @$albums;
	
	return $albums;
}

sub get_item_info_by_url {
	my ($client, $cb, $params, $args) = @_;
	
	my $url  = $args->{url};
	
	$log->debug("Getting information for url: $url");
	
	_get( 
		sub {
			my $items = shift;
			
			if ($items->{album_id}) {
				get_album_info($client, $cb, $params, { 
					album_id => $items->{album_id}, 
					tracks   => $args->{tracks},
					artist   => $args->{artist},
					large_art_url => $args->{image},
				});
			}
			else {
				get_track_info($client, $cb, $params, { 
					track_id => $items->{track_id}, 
					tracks   => $args->{tracks},
					artist   => $args->{artist},
					large_art_url => $args->{image},
				})
			}
		}, 
		$params, 
		{
			_url   => API_URL_URL,
			url    => $url,
		}
	);
}

sub get_album_info {
	my ($client, $cb, $params, $args) = @_;
	
	my $album_id   = $args->{album_id};
	my $get_tracks = $args->{tracks};
	
	$log->debug("Getting tracks for album: $album_id");
	
	_get( 
		sub {
			my $albumInfo = shift;

			$log->error( Data::Dump::dump($albumInfo) ) if ref $albumInfo ne 'HASH';

			$albumInfo->{artist} ||= $args->{artist};
			
			return [ {
				name => $albumInfo->{error},
				type => 'text',
			} ] if $albumInfo->{error};

			my $items = [];

			push @$items, {
				name => (
					cstring($client, $albumInfo->{downloadable} 
						? ($albumInfo->{downloadable} == 1 ? 'PLUGIN_BANDCAMP_FREE' : 'PLUGIN_BANDCAMP_PAID')
						: 'PLUGIN_BANDCAMP_NO_DOWNLOAD'
					)
				),
				type => 'text',
			},
			{
				name => $albumInfo->{url},
				type => 'text',
				weblink => $albumInfo->{url},
			} if ($albumInfo->{downloadable} && $albumInfo->{url});

			push @$items, {
				name => cstring($client, 'PLUGIN_BANDCAMP_ABOUT'),
				items => [{
					name => _cleanup($albumInfo->{about}),
					type => 'text',
					wrap => 1,
				}]
			} if $albumInfo->{about};
			
			push @$items, {
				name => cstring($client, 'PLUGIN_BANDCAMP_CREDITS'),
				items => [{
					name => _cleanup($albumInfo->{credits}),
					type => 'text',
					wrap => 1,
				}]
			} if $albumInfo->{credits};
			
			if ($get_tracks) {
				push @$items, @{ _track_list($client, $albumInfo) };
			}
			
			$cb->( $items, @_ );
		}, 
		$params, 
		{
			_url     => API_URL_ALBUM,
			album_id => $album_id,
		}
	);
}

sub _track_list {
	my ($client, $items) = @_;

	my $tracks = [];
	foreach my $track (@{$items->{tracks}}) {
		$track->{artist} ||= $items->{artist};
		$track->{album}  ||= $items->{title};
		$track->{image}  ||= $track->{large_art_url} || $items->{large_art_url} || $items->{small_art_url};
		$track->{album_url} ||= $items->{url};
		
		# complete with cached values if needed
		if ( my $cached = $cache->set('meta_' . $track->{streaming_url}) ) {
			foreach (keys %$cached) {
				$track->{$_} ||= $cached->{$_}; 
			}
		}
		
		# xxx - track api is broken, returning relative URLs; get domain name from album url
		if ($track->{url} && $track->{url} =~ m|^/| && $track->{album_url}) {
			my ($prefix) = $track->{album_url} =~ m|(http://.*?)/|;
	
			$track->{url} = $prefix . $track->{url};
		}
		
		my $trackinfo = [];

		push @$trackinfo, {
			name => (
				cstring($client, $track->{downloadable} 
					? ($track->{downloadable} == 1 ? 'PLUGIN_BANDCAMP_FREE' : 'PLUGIN_BANDCAMP_PAID')
					: 'PLUGIN_BANDCAMP_NO_DOWNLOAD'
				)
			),
			type => 'text',
		} if ($track->{downloadable} && $track->{url} && $track->{url} =~ /^http/);

		push @$trackinfo, {
			name => $track->{url},
			type => 'text',
			weblink => $track->{url},
		} if ($track->{url} && $track->{url} =~ /^http/);
		
		push @$trackinfo, {
			type => 'link',
			name => cstring($client, 'ARTIST') . cstring($client, 'COLON') . ' ' . $track->{artist},
			url  => \&get_artist_albums,
			passthrough => [{
				band_id => $track->{band_id}
			}]
		} if $track->{artist};
		
		push @$trackinfo, {
			type => 'link',
			name => $track->{album} 
						? cstring($client, 'ALBUM') . cstring($client, 'COLON') . ' ' . $track->{album} 
						: cstring($client, 'PLUGIN_BANDCAMP_OTHER_TRACKS'),
			url  => \&get_album_info,
			passthrough => [{
				album_id => $track->{album_id},
				tracks   => 1,
			}]
		} if $track->{album_id};

		push @$trackinfo, {
			name => cstring($client, 'PLUGIN_BANDCAMP_ABOUT'),
			items => [{
				name => _cleanup($track->{about}),
				type => 'text',
				wrap => 1,
			}]
		} if $track->{about};
		
		push @$trackinfo, {
			name => cstring($client, 'PLUGIN_BANDCAMP_CREDITS'),
			items => [{
				name => _cleanup($track->{credits}),
				type => 'text',
				wrap => 1,
			}]
		} if $track->{credits};
		
		push @$trackinfo, {
			name => cstring($client, 'PLUGIN_BANDCAMP_LYRICS'),
			items => [{
				name => _cleanup($track->{lyrics}),
				type => 'text',
				wrap => 1,
			}]
		} if $track->{lyrics};

		push @$trackinfo, {
			name => cstring($client, 'LENGTH') . cstring($client, 'COLON') . ' ' . sprintf('%s:%02s', int($track->{duration} / 60), $track->{duration} % 60),
			type => 'text',
		} if $track->{duration};

		push @$tracks, {
#			type  => 'link',
			name  => (defined $track->{number} ? $track->{number} . '. ' : '') . $track->{title},
			play  => $track->{streaming_url},
			#image => $track->{large_art_url},
			items => $trackinfo,
			on_select   => 'play',
			playall     => 1,
			passthrough => [{
				track_id => $track->{track_id}
			}]
		};
		
		# cache metadata a little longer...
		$cache->set('meta_' . $track->{streaming_url}, $track, CACHE_TTL * 5) if $track->{streaming_url};
	}
	
	return $tracks;
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
		sub {
			my $items = shift;
			
			$items = _track_list($client, {
				tracks => [ $items ],
				artist => $args->{artist},
				url    => $args->{album_url},
				large_art_url => $args->{large_art_url},
			});

			# sometimes we only want the track-information, but not the track itself			
			if ($args->{notracks} && $items && ref $items eq 'ARRAY' && $items->[0] && ref $items->[0] eq 'HASH' && $items->[0]->{items}) {
				$items = $items->[0]->{items};
			}
			
			$cb->({
				items => $items,
			}, @_ );
		}, 
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