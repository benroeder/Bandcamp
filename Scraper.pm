package Plugins::Bandcamp::Scraper;

use strict;
use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'Bandcamp', 'lib');

use Encode;
use HTML::TreeBuilder;

use Scalar::Util qw(blessed);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use Plugins::Bandcamp::API;

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
	
	main::DEBUGLOG && $log->debug("Searching for tag: $search");

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

	_get($client,
		sub {
			$cb->({
				discography => shift
			});
		},
		sub {
			my $tree   = shift;
			my $result = [];

			my $results = $tree->look_down("_tag", "div", "class", "top-sellers");
			
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

				$cache->set( 'top_sellers', $result, CACHE_TTL );
			}
			
			return $result;
		},
		$params,
		'top_sellers',
		BASE_URL
	);
}

sub get_featured_album {
	my ( $client, $cb, $params ) = @_;

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];

			my $featured = $tree->look_down("_tag", "div", "class", "featured-album");
			
			if ($featured) {
				my $item = {};
				
				my $img = $featured->find('img')->attr('src');
				my $url = $featured->find('a')->attr('href'); 
				$url =~ s/\?from=featuredalbum$//;
					 
				my $header = $featured->find_by_attribute('class', 'featured-album-header')->as_text;
				$header =~ s/Album of the Week, //i if $header;

				my $title = $featured->find_by_attribute('class', 'featured-album-title');
				$title = $title->find('a')->content if $title;
				$title = ref $title eq 'ARRAY' ? $title->[0] : undef;
				
				my $artist;
				if ($title) {
					($artist, $title) = split /:/, $title;
					$title =~ s/^\s*//;
				}
				
				my @text = $featured->look_down('_tag', 'div', 'class', qr/featured[a-z\-]+text/);
				my $review = '';
				foreach my $block (@text) {
					my @lines = $block->look_down('_tag', 'p');
					
					foreach my $line (@lines) {
						$review .= $line->as_text . "\n\n";
					}
				}
				
				push @$result, {
					header => $header,
					title  => $title,
					artist => $artist,
					large_art_url => $img,
					url    => $url,
					review => $review,
				};
				
				$cache->set( 'featured_album', $result, CACHE_TTL );
			}

			return $result
		},
		$params,
		'featured_album',
		BASE_URL
	);
}

sub get_tag_list {
	my ( $client, $cb, $params ) = @_;
	
	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];

			my @categories = $tree->look_down("_tag", "div", "class", qr/tagcloud/);

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

			$cache->set( 'taglist', $result, CACHE_TTL ) if @$result;

			return $result;
		},
		$params,
		'taglist',
		TAGS_BASE_URL,
	);
}


sub get_tag_items {
	my ($client, $cb, $params, $args) = @_;
	
	_get($client,
		sub {
			$cb->({
				discography => shift
			});
		},
		sub {
			my $tree   = shift;
			my $result = [];

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
					
					my $meta = {
						title  => $title,
						artist => $artist,
						large_art_url => $img,
						url    => $url,
					};
					
					# pre-fetch track information
					if ($url =~ m|/track/|) {
						Plugins::Bandcamp::API::get_item_info_by_url($client,
							sub {
								my ($items) = shift;
			
								if ($items->{track_id}) {
									Plugins::Bandcamp::API::get_track_info($items);
								}
							}, 
							$params,
							$meta,
						);
					}
					
					push @$result, $meta;
				} 

				$cache->set( 'tag_album_' . $args->{tag_url}, $result, CACHE_TTL );
			}
			
			return $result;
		},
		$params,
		'tag_album_' . $args->{tag_url},
		$args->{tag_url}
	);
}

sub _get {
	my ($client, $cb, $parseCB, $params, $tag, $url) = @_;

	if (my $cached = $cache->get($tag)) {
		main::DEBUGLOG && $log->debug("found cached value for '$tag': " . Data::Dump::dump($cached));
		$cb->( $cached );
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
				
				$result = $parseCB->($tree) if $parseCB;

				if (!scalar @$result) {
					$result = [];
				}
			}
			else {
				$log->error("Invalid data");
				$result = { 
					error => 'Error: Invalid data',
				};
			}

			main::DEBUGLOG && $log->debug(Data::Dump::dump($result));
			
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