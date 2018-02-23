package Plugins::Bandcamp::API;

# implement http://bandcamp.com/developer

use strict;
use Encode;
use JSON::XS::VersionOneAndTwo;
use URI::Escape;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use constant API_URL_ALBUM => 'http://api.bandcamp.com/api/album/2/info';
use constant API_URL_BAND  => 'http://api.bandcamp.com/api/band/3/';
use constant API_URL_TRACK => 'http://api.bandcamp.com/api/track/3/info';
use constant API_URL_URL   => 'http://api.bandcamp.com/api/url/1/info';
use constant API_URL_COLLECTION => 'https://bandcamp.com/api/fancollection/1/';
use constant ARTWORK_URL   => 'http://f0.bcbits.com/';

use constant CACHE_TTL     => 3600 * 12;
use constant META_CACHE_TTL=> 86400 * 30;
use constant USER_CACHE_TTL=> 60 * 5;

my $log = logger('plugin.bandcamp');

my ($dk, $cache);

sub init {
	($cache, $dk) = @_;
	$dk =~ s/-//g;
}

sub get_fan_collection {
	my ( $client, $cb, $params, $args ) = @_;

	if ( my $cached = $cache->get('api_' . $args->{endpoint} . $args->{fan_id}) ) {
		main::INFOLOG && $log->is_info && $log->info('found cached api response: ' . API_URL_COLLECTION . $args->{endpoint});
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));

		$cb->($cached);
		return;
	}

	_post(
		sub {
			my $result = shift;

			my $type = '';
			my $items;

			if ($result->{items}) {
				$type = 'albums';
				$items = parse_album_list($result->{items});
			}
			elsif ($result->{followeers}) {
				$type = 'artists';
				$items = parse_artist_list($result->{followeers});
			}

			my $data = {
				type  => $type,
				items => $items
			};

			$cache->set('api_' . $args->{endpoint} . $args->{fan_id}, $data, USER_CACHE_TTL);

			$cb->($data);
		},
		$params,
		{
			_url => API_URL_COLLECTION . $args->{endpoint},
			data => {
				fan_id => $args->{fan_id},
				older_than_token => $args->{token} || time() . ':0:a::',
				count => 5000,
			},
		}
	)
}

sub parse_album_list {
	return [ grep { $_ } map {
		if ($_->{album_id}) {
			{
				title  => $_->{item_title} || $_->{album_title} || $_->{featured_track_title},
				artist => $_->{band_name},
				url    => $_->{item_url},
				large_art_url => $_->{item_art_url} || get_artwork_url_from_id($_->{item_art_id}),
			}
		}
	} @{$_[0]} ];
}

sub parse_artist_list {
	return [ grep { $_ } map {
		if ($_->{fan_id} || $_->{band_id}) {
			my $id = 'band_id';

			if ( $_->{fan_id} ) {
				$id = 'fan';
				if ( $_->{trackpipe_url} && $_->{trackpipe_url} =~ m|([^/]*)$| ) {
					$_->{fan_id} = $1;
				}
			}

			my $img = $_->{image_id} && get_artwork_url_from_id($_->{image_id}, undef, '');
			$img  ||= $_->{art_id} && get_artwork_url_from_id($_->{art_id});

			{
				name => $_->{name},
				large_art_url => $img || '',
				$id => $_->{fan_id} || $_->{band_id},
			}
		}
	} @{$_[0]} ];
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
		sub {
			my $items = shift;

			# keep track information in the cache
			foreach my $item (@{$items->{discography}}) {
				$cache->set('small_' . $item->{large_art_url} || $item->{art_lg_url}, $item->{small_art_url}, META_CACHE_TTL);
			}

			$cb->($items) if $cb;
		},
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

	# Bandcamp usually doesn't use the leading www.
	$url =~ s/(?:http?:\/\/|)www\.//;

	# some URLs come with an invalid http:http:// prefix
	$url =~ s/^https?:https?:\/\///;

	main::INFOLOG && $log->is_info && $log->info("Getting information for url: $url");

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
				cache_track_info($track, $args);
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

	if (!$track_id) {
		main::DEBUGLOG && $log->is_debug && logBacktrace('Got no track ID!');
		$cb->() if $cb;
		return;
	}

	_get(
		sub {
			my $items = shift;

			if ($items->{track_id}) {
				$items = cache_track_info($items, $args);
			}
			else {
				foreach ( keys %$items ) {
					cache_track_info($items->{$_}, $args->{$_});
				}
			}

			$cb->($items) if $cb;
		},
		undef,
		{
			_url     => API_URL_TRACK,
			_no_escape => 1,
			track_id => $track_id,
		}
	);
}

sub cache_track_info {
	my ($track, $album) = @_;

	if (my $url = $track->{streaming_url}) {
		# sometimes we get a hash for the streaming_url? Pick the 128kbps or some random other stream
		if (ref $url eq 'HASH') {
			$url = $url->{'mp3-128'} || $url->{(keys %$url)[0]};
			$track->{streaming_url} = $url;
		}

		# use album information to complete track information if available
		if ($album) {
			$track->{artist} ||= $album->{artist};
			$track->{album}  ||= $album->{title};
			$track->{image}  ||= $track->{art_lg_url} || $track->{large_art_url} || $album->{art_lg_url} || $album->{large_art_url} || $album->{small_art_url};
			$track->{album_url} ||= $album->{url};
		}

		# complete with cached values if needed
		my $key = $track->{track_id} || track_key($track->{streaming_url});
		if ( my $cached = $cache->get('meta_' . $key) ) {
			foreach (keys %$cached) {
				$track->{$_} ||= $cached->{$_};
			}
		}

		if ( ($track->{art_lg_url} || $album->{art_lg_url} || $track->{large_art_url} || $album->{large_art_url}) && (my $small = $track->{small_art_url} || $album->{small_art_url}) ) {
			$cache->set('small_' . $track->{image}, $small, META_CACHE_TTL);
		}

		# xxx - track api is broken, returning relative URLs; get domain name from album url
		if ($track->{url} && $track->{url} =~ m|^/| && $track->{album_url}) {
			my ($prefix) = $track->{album_url} =~ m|(http://.*?)/|;

			$track->{url} = $prefix . $track->{url};
		}

		$cache->set('meta_' . $key, $track, META_CACHE_TTL);
	}

	return $track;
}

# 0 => original (size & format, don't use extension)
# 1 => fullsize (dito, use .original?, even heavier?!?)
# 2 => 350x350 jpg
# 3 => 100x100 jpg
# 4 => 300x300 jpg
# 5 => 700x700 jpg
# 7 => 150x150 jpg
# 8 => 124x124 jpg
# 9 => 210x210 jpg
# non-artwork related, but working?
# 20 => 1024x1024 jpg
# 22 => 25x25 jpg
# 41 => 210x210 jpg
# 42 => 50x50 jpg
sub get_artwork_url_from_id {
	my ($image_id, $format, $type) = @_;

	$type = 'a' unless defined $type;
	$format ||= 2; # to be tweaked!

	$image_id = substr("000000000" . $image_id, -10);

	return sprintf('%simg/%s%s_%s.jpg', ARTWORK_URL, $type, $image_id, $format);
}

#  url_hints => {
#        custom_domain => "vestbotrio.com",
#        "custom_domain_verified" => 1,
#        item_type => "a",
#        slug => "flowmotion",
#        subdomain => "vestbotrio",
#      },
#  url_hints => {
#        custom_domain => undef,
#        "custom_domain_verified" => undef,
#        item_type => "a",
#        slug => "git-witt-u",
#        subdomain => "fsgreen",
#      },
my $item_types = {
	a => 'album',
	t => 'track',    # just a guess...
	p => 'merch',
};

sub get_complete_url {
	return 'http:' . $_[0];
}

sub get_url_from_hints {
	my $hints = shift;

	my $url = $hints->{custom_domain};
	$url  ||= $hints->{subdomain};

	return unless $url;

	$url .= '.bandcamp.com' unless $hints->{custom_domain};

	return sprintf('http://%s/%s/%s', $url, $item_types->{$hints->{item_type}}, $hints->{slug});
}

sub track_key {
	my $url = shift;

	if ($url =~ /id=(\d+)/i) {
		return $1;
	}
	elsif ($url =~ /bcbits.*?\/stream\/.*?\/(\d+)\?/i) {
		return $1;
	}

	return '';
}

sub _get {
	my ( $cb, $params, $args ) = @_;

	my $url = (delete $args->{_url}) . ($args->{_nokey} ? '?' : '?key=' . $dk);

	for my $k ( keys %{$args} ) {
		next if $k =~ /^_/;
		$url .= '&' . $k . '=' . ($args->{_no_escape} ? $args->{$k} : URI::Escape::uri_escape_utf8( Encode::decode( 'utf8', $args->{$k} ) ));
	}

	main::DEBUGLOG && $log->debug($url);

	if (my $cached = $cache->get('api_' . $url)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('found cached api response' . Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&cb,
		\&ecb,
		{
			params  => $params,
			timeout => 30,
			cb      => $cb,
			nocache => $args->{_nocache},
			args    => $args
		},
	)->get($url);
}

sub _post {
	my ( $cb, $params, $args ) = @_;

	my $url = $args->{_url};

	my $data = ref $args->{data} ? encode_json($args->{data}) : $args->{data};

	main::INFOLOG && $log->info($url);
	main::DEBUGLOG && $log->debug(Data::Dump::dump($data));

	# if ( my $cached = $cache->get('api_' . $url . $args->{_cacheId}) ) {
	# 	main::DEBUGLOG && $log->is_debug && $log->debug('found cached api response' . Data::Dump::dump($cached));
	# 	$cb->($cached);
	# 	return;
	# }

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&cb,
		\&ecb,
		{
			params  => $params,
			timeout => 30,
			cb      => $cb,
			args    => $args
		},
	)->post($url, 'Content-Type', $args->{ct} || 'application/json', $data);
}

sub cb {
	my $http = shift;
	my $cb   = $http->params('cb');

	my $result;

	if ( $http->headers->content_type =~ /json/ ) {
		$result = decode_json(
			$http->content,
		);

		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

		if ( !$result || $result->{error} ) {
			$result = {
				error => 'Error: ' . ($result->{error_message} || 'Unknown error')
			};

			$log->error($result->{error} . ' (' . $http->url . ')');
		}
		elsif ( !$http->params('nocache') && $http->type ne 'POST' ) {
			$cache->set('api_' . $http->url, $result, CACHE_TTL);
		}
	}
	else {
		$log->error("Invalid data");
		$result = {
			error => 'Error: Invalid data',
		};
	}

	$cb->($result) if $cb;
}

sub ecb {
	my ($http, $error) = @_;

	my $params = $http->params('params');
	my $cb     = $params->{cb};

	$log->warn("error: $error");
	main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

	$cb->([ {
		name => 'Unknown error: ' . $error,
		type => 'text'
	} ]) if $cb;
}

1;