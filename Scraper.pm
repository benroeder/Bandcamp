package Plugins::Bandcamp::Scraper;

use strict;
use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'Bandcamp', 'lib');

use Encode;
use HTML::TreeBuilder;

use Scalar::Util qw(blessed);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;

use constant BASE_URL      => 'http://bandcamp.com/';
use constant TAGS_BASE_URL => BASE_URL . 'tags/';
use constant TAG_BASE_URL  => BASE_URL . 'tag/';
use constant CACHE_TTL     => 3600 * 12;

my $log = logger('plugin.bandcamp');

my $cache;

sub init {
	$cache = shift;
}

sub search_tags {
	my ($client, $cb, $args) = @_;

	my $search = $args->{search};
	my $params = $args->{params};
	
	$search =~ s/ /-/g;
	
	$log->debug("Searching for tag: $search");

	get_tag_items($client,
		$cb, 
		$params, 
		{
			tag_url => TAG_BASE_URL . $search
		}
	);
}

sub get_top_sellers {
	my ( $client, $cb, $params ) = @_;

	if (my $cached = $cache->get('top_sellers')) {
		$log->debug('found cached top sellers list: ' . Data::Dump::dump($cached));
		$cb->({
			discography => $cached
		});
		return;
	}

	
	_get($client,
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			
			my $result;

			if ( $response->headers->content_type =~ /html/ ) {
				my $tree = HTML::TreeBuilder->new;
				$tree->parse_content( Encode::decode( 'utf8', $response->content) );
				
				$result = [];

				my $results   = $tree->look_down("_tag", "div", "class", "top-sellers");
				
				if ($results) {
					my $item_list = $results->look_down("_tag", "ul", "class", "list");
	
					foreach ($item_list->content_list) {
	
						my $img = $_->find('img')->attr('src');
						my $url = $_->find('a')->attr('href'); 
						$url =~ s/\?from=topsellers$//;
						 
						my $title = $_->find_by_attribute('class', 'album-name');
						$title = $title->find('a')->content if $title;
						$title = ref $title eq 'ARRAY' ? $title->[0] : undef;
						
						my $artist = $_->find_by_attribute('class', 'album-artist');
						$artist = $artist->find('a')->content if $artist;
						$artist = ref $artist eq 'ARRAY' ? $artist->[0] : undef;
						
						next unless ($title || $artist) && $url;
						
						push @$result, {
							title  => $title,
							artist => $artist,
							large_art_url => $img,
							url    => $url,
						}
					} 
	
					@$result = sort { uc($a->{name}) cmp uc($b->{name}) } @$result;
					
					$cache->set( 'top_sellers', $result, CACHE_TTL );
				}
				else {
					$result = [{
						name => cstring($client, 'EMPTY'),
						type => 'text',
					}]
				}
				
				$result = {
					discography => $result
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
		$params,
		BASE_URL
	);
}

sub get_tag_list {
	my ( $client, $cb, $params ) = @_;
	
	if (my $cached = $cache->get('taglist')) {
		$log->debug('found cached tag list');
		$cb->($cached);
		return;
	}
	
	_get($client,
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
				
				$cache->set( 'taglist', $result, CACHE_TTL );
			}
			else {
				$log->error("Invalid data");
				$result = [{ 
					error => 'Error: Invalid data',
				}];
			}
			$cb->($result);
		},
		$params,
		TAGS_BASE_URL,
	);
}


sub get_tag_items {
	my ($client, $cb, $params, $args) = @_;

	if (my $cached = $cache->get('tag_album_' . $args->{tag_url})) {
		$log->debug('found cached album list: ' . Data::Dump::dump($cached));
		$cb->({
			discography => $cached
		});
		return;
	}
	
	_get($client,
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			
			my $result;

			if ( $response->headers->content_type =~ /html/ ) {
				my $tree = HTML::TreeBuilder->new;
				$tree->parse_content( Encode::decode( 'utf8', $response->content) );
				
				$result = [];

				my $results   = $tree->look_down("_tag", "div", "class", "results");
				
				if ($results) {
					my $item_list = $results->look_down("_tag", "ul", "class", "item_list");
	
					foreach ($item_list->content_list) {
	
						my $img = $_->find('img')->attr('src');
						my $url = $_->find('a')->attr('href'); 
						 
						my $title = $_->find_by_attribute('class', 'itemtext')->content;
						$title = ref $title eq 'ARRAY' ? $title->[0] : undef;
						
						my $artist = $_->find_by_attribute('class', 'itemsubtext')->content;
						$artist = ref $artist eq 'ARRAY' ? $artist->[0] : undef;
						
						next unless ($title || $artist) && $url;
						
						push @$result, {
							title  => $title,
							artist => $artist,
							large_art_url => $img,
							url    => $url,
						}
					} 
	
					@$result = sort { uc($a->{name}) cmp uc($b->{name}) } @$result;
					
					$cache->set( 'tag_album_' . $args->{tag_url}, $result, CACHE_TTL );
				}
				else {
					$result = [{
						name => cstring($client, 'EMPTY'),
						type => 'text',
					}]
				}
				
				$result = {
					discography => $result
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
		$params,
		$args->{tag_url}
	);
}

sub _get {
	my ($client, $cb, $params, $url) = @_;

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		$cb,
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