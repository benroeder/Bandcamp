package Plugins::Bandcamp::API::Common;

use strict;

use Digest::MD5 qw(md5_hex);
use Encode;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant BASE_URL  => 'https://bandcamp.com';
use constant CACHE_TTL => 3600 * 12;

my $prefs = preferences('plugin.bandcamp');
my $log = logger('plugin.bandcamp');

my ($cache, $dk);

sub init {
	my ($class, $pluginData) = @_;

	$pluginData ||= {};

	$cache = Slim::Utils::Cache->new('bandcamp', $pluginData->{cacheVersion});
	$dk = $pluginData->{dk};
	$dk =~ s/-//g;

	return wantarray ? ($cache, $dk) : $cache;
}

sub calculateLibraryChecksum {
	my $summary = shift || return;

	my $checksum;
	if (ref $summary && $summary->{collection_summary}) {
		my $albums = $summary->{collection_summary}->{tralbum_lookup} || {};
		$checksum = md5_hex(join('::', sort grep {
			!$albums->{$_}->{purchased}
		} keys %$albums));
	}

	main::INFOLOG && $log->is_info && $log->info("Library checksum: $checksum");
	return $checksum;
}

sub extendUrl {
	my ($class, $args) = @_;

	my $url = delete $args->{_url};
	$url = BASE_URL . $url unless $url =~ /^http/;

	my $method = $args->{_method} || 'GET';
	my $data;

	if ($method eq 'POST') {
		$data = ref $args->{data} ? encode_json($args->{data}) : $args->{data};

		main::INFOLOG && $log->info($url . ": \n" . Data::Dump::dump($data));
	}
	else {
		$url .= ($args->{_nokey} ? '?' : '?key=' . $dk);

		for my $k ( keys %{$args} ) {
			next if $k =~ /^_/;
			$url .= '&' . $k . '=' . ($args->{_no_escape} ? $args->{$k} : uri_escape_utf8( Encode::decode( 'utf8', $args->{$k} ) ));
		}

		$url =~ s/\?&/?/;
		$url =~ s/\?$//;

		main::INFOLOG && $log->info($url);
	}


	return wantarray ? ($url, $data) : $url;
}

sub parseResult {
	my ($http, $args) = @_;

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
			$cache->set('api_' . $http->url, $result, $http->params('_cacheTTL') || CACHE_TTL);
		}
		elsif ( $args && $args->{_cacheKey} ) {
			$cache->set('api_' . $args->{_cacheKey}, $result, $args->{'_cacheTTL'} || CACHE_TTL);
		}
	}
	else {
		$log->error("Invalid data");
		$result = {
			error => 'Error: Invalid data',
		};
	}

	return $result;
}

1;