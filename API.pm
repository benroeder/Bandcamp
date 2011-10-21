package Plugins::Bandcamp::API;

use strict;
use Encode;
use JSON::XS::VersionOneAndTwo;
use URI::Escape;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use constant API_KEY       => 'perladruslasaemingserligr';
use constant API_URL_ALBUM => 'http://api.bandcamp.com/api/album/2/';
use constant API_URL_BAND  => 'http://api.bandcamp.com/api/band/3/';
use constant API_URL_TRACK => 'http://api.bandcamp.com/api/track/1/';
use constant API_URL_URL   => 'http://api.bandcamp.com/api/url/1/';

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
			url   => \&artist_albums,
			passthrough => [{
				artist_id => $artist->{band_id},
			}],
			type  => 'link',
		}
	}
	
	return $artists;
}

sub artist_albums {
	my ($client, $cb, $params, $args) = @_;
	
	logBacktrace(Data::Dump::dump($args));
}


sub _get {
	my ( $client, $cb, $params, $args ) = @_;
	
	my $url = (delete $args->{url}) . '?key=' . API_KEY;
		
	for my $k ( keys %{$args} ) {
		$url .= '&' . $k . '=' . URI::Escape::uri_escape_utf8( Encode::decode( 'utf8', $args->{$k} ) );
	}
	
	$log->debug($url);
	
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
				
				if ( !$result || $result->{error} || !$result->{results} || ref $result->{results} ne 'ARRAY' ) {
					$result = {
						error => 'Error: ' . ($result->{error_message} || 'Unknown error')
					};
					$log->error($result->{error});
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
			client  => $client,
			timeout => 30,
		},
	)->get($url);
}



1;