package Plugins::Bandcamp::Scraper;

use strict;
use Encode;
use HTML::TreeBuilder;
use Scalar::Util qw(blessed);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::Bandcamp::API;

use constant TAGS_BASE_URL => 'http://bandcamp.com/tags/';
use constant TAG_BASE_URL  => 'http://bandcamp.com/tag/';
use constant CACHE_TTL     => 3600 * 12;

my $log = logger('plugin.bandcamp');

sub search_tags {
	my ($client, $cb, $args) = @_;

	my $search = $args->{search};
	my $params = $args->{params};
	
	$search =~ s/ /-/g;
	
	$log->debug("Searching for tag: $search");

	get_tag_items($client, 
		sub {
			my $items = shift;
			
			$cb->( {
				items => $items
			} );
		}, $params, {
		tag_url => TAG_BASE_URL . $search
	});
}

sub get_tags {
	my ($client, $cb, $params) = @_;

	_get_tag_list($client,
		sub {
			my $items = shift;
			$cb->( _tag_list([ grep { $_->{cloud} eq 'tags_cloud' } @$items ]) );
		},
		$params,
	);
}

sub get_locations {
	my ($client, $cb, $params) = @_;

	_get_tag_list($client,
		sub {
			my $items = shift;
			$cb->( _tag_list([ grep { $_->{cloud} eq 'locations_cloud' } @$items ]) );
		},
		$params,
	);
}

sub _tag_list {
	my $items = shift;;
	
	my $results = [];
	
	foreach my $item ( @$items ) {
		push @$results, {
			name => $item->{name},
			url  => \&get_tag_items,
			type => 'link',
			passthrough => [ { tag_url => $item->{url} } ]
		}
	}
	
	return $results;
}

sub _get_tag_list {
	my ( $client, $cb, $params ) = @_;
	
	my $cache = Slim::Utils::Cache->new;
	
	if (my $cached = $cache->get('plugin_bandcamp_taglist')) {
		$log->debug('found cached tag list');
		$cb->($cached);
		return;
	}
	
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			
			my $result;

			if ( $response->headers->content_type =~ /html/ ) {
				my $tree = HTML::TreeBuilder->new;
				$tree->parse_content( Encode::decode( 'utf8', $response->content) );
				
				my @categories = $tree->look_down("_tag", "div", "class", qr/tagcloud/);

				$result = [];
				
				foreach my $tag_cloud (@categories) {
					my $type = $tag_cloud->attr('id') || next;
					
					foreach ($tag_cloud->content_list) {
						next unless blessed($_) && $_->attr('class') =~ /\btag\b/ && ref $_->content eq 'ARRAY';
						
						push @$result, {
							name  => $_->content->[0],
							url   => $_->attr('href'),
							cloud => $type,
						}
					} 
				}

				@$result = sort { uc($a->{name}) cmp uc($b->{name}) } @$result;

#				main::DEBUGLOG && $log->debug(Data::Dump::dump($result));
				
				$cache->set( 'plugin_bandcamp_taglist', $result, CACHE_TTL );
			}
			else {
				$log->error("Invalid data");
				$result = [{ 
					error => 'Error: Invalid data',
				}];
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
	)->get(TAGS_BASE_URL);
}


sub get_tag_items {
	my ($client, $cb, $params, $args) = @_;

	my $cache = Slim::Utils::Cache->new;
	
	if (my $cached = $cache->get('plugin_bandcamp_tag_album_' . $args->{tag_url})) {
		$log->debug('found cached album list');
		_tag_album_list($cb, $cached);
		return;
	}
	
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			
			my $result;

			if ( $response->headers->content_type =~ /html/ ) {
				my $tree = HTML::TreeBuilder->new;
				$tree->parse_content( Encode::decode( 'utf8', $response->content) );
				
				my $results   = $tree->look_down("_tag", "div", "class", "results");
				my $item_list = $results->look_down("_tag", "ul", "class", "item_list");

				$result = [];
				
				foreach ($item_list->content_list) {

					my $img = $_->find('img')->attr('src');
					my $url = $_->find('a')->attr('href'); 
					 
					my $album = $_->find_by_attribute('class', 'itemtext')->content;
					$album = ref $album eq 'ARRAY' ? $album->[0] : undef;
					
					my $artist = $_->find_by_attribute('class', 'itemsubtext')->content;
					$artist = ref $artist eq 'ARRAY' ? $artist->[0] : undef;
					
					next unless ($album || $artist) && $url;
					
					push @$result, {
						album  => $album,
						artist => $artist,
						image  => $img,
						url    => $url,
					}
				} 

				@$result = sort { uc($a->{name}) cmp uc($b->{name}) } @$result;
				
				$cache->set( 'plugin_bandcamp_tag_album_' . $args->{tag_url}, $result, CACHE_TTL );
			}
			else {
				$log->error("Invalid data");
				$result = [{ 
					error => 'Error: Invalid data',
				}];
			}
			_tag_album_list($cb, $result);
		},
		sub {
			$log->warn("error: $_[1]");
			_tag_album_list($cb, [ { 
				name => 'Unknown error: ' . $_[1],
				type => 'text' 
			} ]);
		},
		{
			params  => $params,
			client  => $client,
			timeout => 30,
		},
	)->get($args->{tag_url});
}

sub _tag_album_list {
	my ( $cb, $items ) = @_;
	
	my $result = [];

	foreach (@$items) {
		push @$result, {
			type  => 'playlist',
			name  => $_->{album} . ($_->{artist} ? ' - ' . $_->{artist} : ''),
			line1 => $_->{artist} ? $_->{album} : undef,
			line2 => $_->{artist},
			url   => \&Plugins::Bandcamp::API::get_item_info_by_url,
			image => $_->{image},
			passthrough => [{
				album_url => $_->{url},
				artist    => $_->{artist},
				tracks    => 1,
			}],
		};
	}

	$cb->($result);
}

1;