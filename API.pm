package Plugins::Bandcamp::API;

# implement http://bandcamp.com/developer

use strict;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use Plugins::Bandcamp::API::Common;

use constant BASE_URL      => 'https://bandcamp.com/';
use constant API_URL_ALBUM => BASE_URL . 'api/album/2/info';
use constant API_URL_BAND  => BASE_URL . 'api/band/3/';
use constant API_URL_TRACK => BASE_URL . 'api/track/3/info';
use constant API_URL_URL   => BASE_URL . 'api/url/1/info';
use constant API_URL_COLLECTION => BASE_URL . 'api/fancollection/1/';
use constant API_URL_MUSIC_FEED => BASE_URL . 'fan_dash_feed_updates';
use constant API_URL_WEEKLY => BASE_URL . 'api/bcweekly/2/';

use constant ARTWORK_URL   => 'http://f0.bcbits.com/';

use constant META_CACHE_TTL=> 86400 * 30;
use constant USER_CACHE_TTL=> 60 * 5;

use constant MAX_FEED_ITEMS => 100;

my $log = logger('plugin.bandcamp');

my ($dk, $cache);

sub init {
	($cache, $dk) = Plugins::Bandcamp::API::Common->init(@_);
}

sub get_fan_collection {
	my ( $client, $cb, $params, $args ) = @_;

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

			$cb->($data);
		},
		$params,
		{
			_url => API_URL_COLLECTION . $args->{endpoint},
			_cacheKey => $args->{endpoint} . $args->{fan_id},
			_cacheTTL => USER_CACHE_TTL,
			data => {
				fan_id => $args->{fan_id},
				older_than_token => $args->{token} || time() . ':0:a::',
				count => 5000,
			},
		}
	)
}

sub fan_dash_feed_updates {
	my ( $client, $cb, $params, $args ) = @_;

	# we'll default to a "rounded" now - rounded to 100s, which effectively gives us caching for shy of two minutes
	$args->{story_date} ||= int(time()/USER_CACHE_TTL) * USER_CACHE_TTL;

	_post(
		sub {
			my $result = shift;

			my $entries = {};
			eval {
				map {
					$entries->{$_->{featured_track}} = $_;
				} @{$result->{stories}->{entries}};
			};

			my $feed = $args->{feed} || [];
			my $oldest_story_date;
			my $tracks = eval { $result->{stories}->{track_list} };

			if ( $tracks && scalar @$tracks ) {
				foreach my $item (@$tracks) {
					my $type = $item->{tralbum_type} || '';

					my $track = {
						title    => $item->{title},
						artist   => $item->{band_name},
						band_id  => $item->{band_id},
						album    => $item->{album_title},
						album_id => $item->{album_id},
						large_art_url => get_artwork_url_from_id($item->{art_id}),
						track_id => $item->{track_id},
						streaming_url => $item->{streaming_url},
						duration => $item->{duration},
					};

					if ( my $entry = $entries->{$item->{track_id}} ) {
						$track->{url} = $entry->{item_url};
						$track->{album_url} = $entry->{item_url};
					}

					push @$feed, cache_track_info($track);
				}

				$oldest_story_date = eval {
					$result->{stories}->{oldest_story_date}
				};
			}

			# there's more to grab - get it
			if ( $oldest_story_date && scalar @$feed < MAX_FEED_ITEMS ) {
				$args->{story_date} = $oldest_story_date;
				$args->{feed} = $feed;
				fan_dash_feed_updates($client, $cb, $params, $args);
				return;
			}

			if (!scalar @$feed && ref $result eq 'ARRAY' ) {
				# we'd get a "400 bad request" if the identity token was invalid
				if (scalar @$result == 1 && ($result->[0]->{name} || '') =~ /Unknown error.*400/) {
					$feed = [{
						type => 'text',
						name => Slim::Utils::Strings::cstring($client, 'PLUGIN_BANDCAMP_IDENTITY_TOKEN_INVALID')
					}];
					$log->error($feed->[0]->{name});
				}
				else {
					$feed = $result;
				}

				$cb->({
					error => $feed
				});
			}
			else {
				$cb->({
					tracks => $feed,
				});
			}
		},
		$params,
		{
			_url => API_URL_MUSIC_FEED,
			_ct => 'application/x-www-form-urlencoded',
			_cacheKey => 'music_feed_' . $args->{fan_id} . $args->{story_date},
			# data is cached with timestamp, therefore we can keep this "forever", cache key would change if needed
			_cacheTTL => META_CACHE_TTL,
			data => sprintf('fan_id=%s&older_than=%s', $args->{fan_id}, $args->{story_date}),
		}
	);
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
	$url =~ s/(?:https?:\/\/|)www\.//;

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

=pod replaced with Scraper::get_album_info
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
=cut

sub get_weekly_shows {
	my ($cb, $args) = @_;

	_get(
		sub {
			my $result = shift;

			my $items = [];

			if ($result && ref $result && $result->{results}) {
				$items = [ map {
					$_->{date} =~ s/^(\d+ \w+ \d+).*/$1/;
					$_->{large_art_url} = get_artwork_url_from_id($_->{v2_image_id} || $_->{image_id}, 5, '');
					$_;
				} @{$result->{results}} ]
			}

			$cb->($items) if $cb;
		},
		undef,
		{
			_url => API_URL_WEEKLY . 'list',
			_nokey => 1,
		}
	)
}

sub get_weekly_show {
	my ($cb, $args) = @_;

	_get(
		sub {
			my $result = shift;

			my $tracks = [];
			my $podcast;

			if ($result && ref $result && $result->{tracks}) {
				$result->{date} =~ s/^(\d+ \w+ \d+).*/$1/;

				my $podcastData = cache_track_info({
					title    => $result->{subtitle},
					artist   => $result->{date},
					track_id => $result->{audio_track_id},
					duration => $result->{audio_duration},
					image    => get_artwork_url_from_id($result->{show_v2_image_id}, 5, ''),
					streaming_url => $result->{audio_stream},
				});

				$podcast = $podcastData->{streaming_url};

				foreach ( @{$result->{tracks}} ) {
					my $cover = get_artwork_url_from_id($_->{track_art_id});
					push @$tracks, cache_track_info({
						title    => $_->{title},
						artist   => $_->{artist},
						band_id  => $_->{band_id},
						album    => $_->{album_title},
						album_url=> $_->{album_url},
						album_id => $_->{album_id},
						image    => $cover,
						large_art_url => $cover,
						track_id => $_->{track_id},
						url      => $_->{url},
					});
				}
			}

			my $items = {
				tracks => $tracks,
				podcast => $podcast,
				description => $result->{desc}
			};

			my %tracks;
			foreach my $track ( @$tracks ) {
				$tracks{$track->{track_id}} = $track;
			}

			# sort IDs to improve caching
			_get_weekly_track_infos($items, \%tracks, [ sort keys %tracks ], sub {
				$cb->($items);
			}) if $cb;
		},
		undef,
		{
			_url => API_URL_WEEKLY . 'get',
			_nokey => 1,
			id => $args->{show_id},
		}
	)
}

sub _get_weekly_track_infos {
	my ($show, $tracks, $trackIds, $cb) = @_;

	$tracks->{track_id} = join(',', splice(@$trackIds, 0, 50));

	get_track_info($tracks, sub {
		my $trackInfo = shift;

		foreach my $track ( @{ $show->{tracks} }) {
			if (my $details = $trackInfo->{$track->{track_id}}) {
				foreach (qw(downloadable album_id about credits lyrics duration streaming_url)) {
					$track->{$_} ||= $details->{$_} if $details->{$_};
				}
			}
		}

		if (scalar @$trackIds) {
			_get_weekly_track_infos($show, $tracks, $trackIds, $cb);
		}
		else {
			$cb->() if $cb;
		}
	});
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

			if ($items && ref $items && ref $items eq 'HASH') {
				if ($items->{track_id}) {
					$items = cache_track_info($items, $args);
				}
				else {
					foreach ( keys %$items ) {
						cache_track_info($items->{$_}, $args->{$_});
					}
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

		$track->{title} = HTML::Entities::decode_entities($track->{title});

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
# 10 => 1200x1200 jpg
# non-artwork related, but working?
# 20 => 1024x1024 jpg
# 22 => 25x25 jpg
# 41 => 210x210 jpg
# 42 => 50x50 jpg
sub get_artwork_url_from_id {
	my ($image_id, $format, $type) = @_;

	$type = 'a' unless defined $type;
	$format ||= 5; # to be tweaked!

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
	my $url = $_[0];

	return $url if $url =~ /^http/;
	return 'http:' . $url;
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
	elsif ($url =~ m|bandcamp://(.*?)\.mp3|) {
		return $1;
	}

	return '';
}

sub _get {
	my ( $cb, $params, $args ) = @_;

	$args->{_method} = 'GET';
	my $url = Plugins::Bandcamp::API::Common->extendUrl($args);

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

	$args->{_method} = 'POST';
	my ($url, $data) = Plugins::Bandcamp::API::Common->extendUrl($args);

	if ( $args->{_cacheKey} && (my $cached = $cache->get('api_' . $args->{_cacheKey})) ) {
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
			args    => $args
		},
	)->post($url, 'Content-Type', $args->{_ct} || 'application/json', $data);
}

sub cb {
	my $http = shift;
	my $cb   = $http->params('cb');
	my $args = $http->params('args');

	my $result = Plugins::Bandcamp::API::Common::parseResult($http, $args);

	$cb->($result) if $cb;
}

sub ecb {
	my ($http, $error) = @_;

	my $params = $http->params('params');
	my $cb     = $http->params('cb');

	$log->warn("error: $error");
	main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

	$cb->([ {
		name => 'Unknown error: ' . $error,
		type => 'text'
	} ]) if $cb;
}

1;