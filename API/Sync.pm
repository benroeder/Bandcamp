package Plugins::Bandcamp::API::Sync;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
# use List::Util qw(max);
# use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Bandcamp::API::Common;

use constant API_URL_ALBUMS => '/api/fancollection/1/wishlist_items';
use constant API_URL_ALBUM  => '/api/album/2/info';

use constant META_CACHE_TTL => 86400 * 30;
use constant USER_CACHE_TTL => 60 * 5;

my $prefs = preferences('plugin.bandcamp');
my $log = logger('plugin.bandcamp');

my ($cache, $dk);

sub init {
	my $class = shift;

	($cache, $dk) = Plugins::Bandcamp::API::Common->init(@_);

	return $cache;
}

sub myAlbums {
	my ($class, $fan_id) = @_;

	my $now = time();
	$fan_id ||= $prefs->get('fan_id');

	my $albumData = _call({
		data => {
			fan_id  => $fan_id,
			older_than_token => time() . ':0:a::',
			count   => 10000
		},
		_url      => API_URL_ALBUMS,
		_method   => 'POST',
		_cacheTTL => USER_CACHE_TTL,
		_cacheKey => 'myAlbums_' . $fan_id
	});

	my $albums = [];

	if ($albumData && ref $albumData && $albumData->{items}) {
		foreach (@{$albumData->{items}}) {
			my $album = {
				added => $_->{added},
				id    => $_->{album_id},
				title => $_->{album_title},
				artist=> $_->{band_name},
				artist_id => $_->{band_id},
				cover => $_->{item_art_url}
				# genre => $_->{genre_id},
			};

			push @$albums, $album;
		}
	}

	return $albums;
}

# get album info, tracks
# curl --location --request GET 'https://bandcamp.com/api/album/2/info?key=perladruslasaemingserligr&album_id=34939844' \
sub getAlbum {
	my ($class, $id) = @_;

	return _call({
		album_id  => $id,
		_url      => API_URL_ALBUM,
		_cacheTTL => META_CACHE_TTL
	});
}


sub _call {
	my ( $args ) = @_;

	$args->{_method} ||= 'GET';

	my ($url, $data) = Plugins::Bandcamp::API::Common->extendUrl($args);

	if ( $args->{_method} eq 'GET' && (my $cached = $cache->get('api_' . $url)) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('found cached api response' . Data::Dump::dump($cached));
		return $cached;
	}
	elsif ( $args->{_cacheKey} && (my $cached = $cache->get('api_' . $args->{_cacheKey})) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('found cached api response' . Data::Dump::dump($cached));
		return $cached;
	}

	my $http = Slim::Networking::SimpleSyncHTTP->new({
		timeout => 15,
	});

	my $response;
	if ($args->{_method} eq 'POST') {
		$response = $http->post($url, 'Content-Type', $args->{_ct} || 'application/json', $data);
	}
	else {
		$response = $http->get($url);
	}

	my $result = Plugins::Bandcamp::API::Common::parseResult($http, $args);

	return $result;
}

1;