package Plugins::Bandcamp::Scraper;

use strict;
use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'Bandcamp', 'lib');

use Encode;
use HTML::TreeBuilder;
use JSON::XS::VersionOneAndTwo;

use Scalar::Util qw(blessed);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use Plugins::Bandcamp::API;

use constant BASE_URL      => 'http://bandcamp.com/';
use constant TAGS_BASE_URL => BASE_URL . 'tags/';
use constant TAG_BASE_URL  => BASE_URL . 'tag/';
use constant DISCOVERY_URL => BASE_URL . 'discover_cb';
use constant API_URL_SALES => BASE_URL . 'cb_homepage_feed';
use constant ALBUM_ART_URL => 'http://f0.bcbits.com/img/a%s_9.jpg';

use constant CACHE_TTL     => 3600 * 12;
use constant META_CACHE_TTL=> 86400 * 30;
use constant USER_CACHE_TTL=> 60 * 5;

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

sub get_fan_page {
	my ( $client, $cb, $params, $args ) = @_;
	
	my $fan = $args->{fan} || '';
	
	main::DEBUGLOG && $log->debug("Getting fan page for: $fan");
	
	my $cache_key = "fanpage/$fan";

	_get($client,
		sub {
			$cb->({
				discography => shift
			});
		},
		sub {
			my $tree   = shift;
			my $result = [];

			# try to read the JSON data in the file
			if ($tree->as_HTML =~ /item_details:.*?(\{.*?})\s*?\};/si) {

				my $collection = eval { from_json( Encode::encode( 'utf8', $1) ) };
				
				if ($@) {
					$log->warn("Failed to parse JSON - falling back to HTML: $@");
				}
				elsif ($collection && ref $collection eq 'HASH') {
					foreach (values %$collection) {
						my $item = {
							title => $_->{item_title} || $_->{featured_track_title},
							artist => $_->{band_name},
							url   => $_->{item_url},
							# XXX - what's the image URL schema?
							large_art_url => $_->{item_art_url} || sprintf(ALBUM_ART_URL, $_->{item_art_id}),
						};
						
						push @$result, $item if ($item->{title} || $item->{artist}) && $item->{url}; 
					}
				}
			}

			# if the JSON data failed, parse the HTML (which would miss the wishlist)
			if (!@$result) {
				my @item_list = $tree->look_down("_tag", "div", "class", "collection-item-gallery-container");

				foreach (@item_list) {

					next unless $_->content_list;
					
					my $img = $_->find('img')->attr('src');
					my $url = $_->look_down('_tag', 'a', 'class', 'item-link')->attr('href');
					
					my $title = $_->find_by_attribute('class', 'collection-item-title');
					$title = $title->content if $title;
					$title = ref $title eq 'ARRAY' ? $title->[0] : undef;
	
					my $artist = $_->find_by_attribute('class', 'collection-item-artist');
					$artist = $artist->content if $artist;
					$artist = ref $artist eq 'ARRAY' ? $artist->[0] : undef;
					$artist =~ s/by // if $artist;
	
					next unless ($title || $artist) && $url;
					
					push @$result, {
						title  => $title,
						artist => $artist,
						large_art_url => $img,
						url    => $url,
					}
				}
			}
			
			@$result = sort { uc($a->{title}) cmp uc($b->{title}) } @$result if @$result;
			
			$cache->set( $cache_key, $result, USER_CACHE_TTL ) if @$result && _shall_cache($params);
			
			return $result;
		},
		$params,
		$cache_key,
		BASE_URL . $fan
	);
}

sub get_fan_following {
	my ( $client, $cb, $params, $args ) = @_;
	
	my $fan = $args->{fan} || '';
	
	main::DEBUGLOG && $log->debug("Getting fan following page for: $fan");

	my $cache_key = "fanpage/$fan/following";

	_get($client,
		sub {
			$cb->({
				results => shift
			});
		},
		sub {
			my $tree   = shift;
			my $result = [];

			my @item_list = $tree->look_down("_tag", "li", "class", "follow-grid-item");

			foreach (@item_list) {
				my $img = $_->look_down('_tag', 'img', 'class', 'lazy')->attr('data-original');
				
				if ( my $artist = $_->find_by_attribute('class', 'band-name') ) {
					$artist = $artist->look_down('_tag', 'a');
					
					next unless $artist;
					
					$artist = $artist->content;
					$artist = ref $artist eq 'ARRAY' ? $artist->[0] : undef;
	
					my ($id) = $_->id =~ /(\d+)$/;
	
					next unless $artist && $id;
	
					push @$result, {
						name => $artist,
						large_art_url => $img,
						band_id => $id,
					}
				}
				elsif ( my $fan = $_->find_by_attribute('class', 'fan-name') ) {
					$fan = $fan->look_down('_tag', 'a');

					next unless $fan;
					
					my ($id) = $fan->attr('href') =~ m|([^/]+)$|s;
					
					$fan = $fan->content;
					$fan = ref $fan eq 'ARRAY' ? $fan->[0] : undef;

					next unless $fan && $id;
	
					push @$result, {
						name => $fan,
						large_art_url => $img,
						fan => $id,
					}
				}
			}
			
			$cache->set( $cache_key, $result, USER_CACHE_TTL ) if @$result && _shall_cache($params);

			return $result;
		},
		$params,
		$cache_key,
		BASE_URL . $fan . '/following',
	);
}

sub get_weekly_shows {
	my ( $client, $cb, $params ) = @_;
	
	if ( my $cached = $cache->get('weekly_show_rendered') ) {
		$cb->($cached);
		return;
	}

	_get($client,
		sub {
			my $items = shift;
			
			# XXX - limit to the latest 4-5 shows?
			
			my $tracks = {};
			foreach my $show ( @$items ) {
				foreach my $track ( @{ $show->{tracks} }) {
					$tracks->{$track->{track_id}} = $track;
				}
			}
			
			_get_weekly_track_infos($items, $tracks, [keys %$tracks], sub {
				$cache->set( 'weekly_show_rendered', $items, 3600 ) if $items && @$items;
				$cb->($items) if $cb;
			});
		},
		sub {
			my $tree   = shift;
			my $result = [];

			my $featured = $tree->look_down("_tag", "div", "id", "pagedata");
			
			if ($featured) {
				my $data = $featured->attr('data-blob');
				
				$data = eval { from_json( Encode::encode( 'utf8', $data) ) };
				
				if ($@ || !$data) {
					$log->error($@);
				}
				elsif ( $data->{bcw_data} && $data->{bcw_seq} ) {

					foreach my $index ( @{$data->{bcw_seq}} ) {
						if ( my $show = $data->{bcw_data}->{$index->{id}} ) {
							my $tracks = [];
							
							foreach ( @{$show->{tracks}} ) {
								my $art = $_->{track_image} || {};
								
								push @$tracks, {
									album_id => $_->{album_id},
									album    => $_->{album_title},
									album_url=> $_->{album_url},
									artist   => $_->{artist},
									band_id  => $_->{band_id},
									title    => $_->{title},
									track_id => $_->{track_id},
									url      => $_->{track_url},
									large_art_url => Plugins::Bandcamp::API::get_artwork_url_from_id($_->{track_art_id}) || $art->{thumb}->{url} || $art->{small}->{url} || $art->{screen}->{url},
								};
		
								# small artwork version
								if ( $art->{thumb}->{url} && $art->{small}->{url} && $art->{thumb}->{url} ne $art->{small}->{url} ) {
									$cache->set('small_' . $art->{thumb}->{url}, $art->{small}->{url}, META_CACHE_TTL);
								}
		
								# full size smallwork
								if ( $art->{screen}->{url} && $art->{thumb}->{url} && $art->{screen}->{url} ne $art->{thumb}->{url} ) {
									$cache->set('full_' . $art->{thumb}->{url}, $art->{screen}->{url}, META_CACHE_TTL);
								}
							}
							
							$index->{date} =~ /^(\d+) (\w+) (\d+)/;
							my $date = "$1 $2 $3";
							
							push @$result, {
								date  => $date,
								subtitle => $show->{subtitle},
								description => $show->{desc},
								large_art_url => Plugins::Bandcamp::API::get_artwork_url_from_id($show->{show_image_id}, 0, '') || $show->{show_image}->{url} || $show->{show_screen_image}->{url},
								tracks => $tracks,
							};

							if ( $show->{show_image}->{url} && $show->{show_screen_image}->{url} && $show->{show_image}->{url} ne $show->{show_screen_image}->{url} ) {
								$cache->set('full_' . $show->{show_image}->{url}, $show->{show_screen_image}->{url}, META_CACHE_TTL);
							}
						} 
					}

				}
				
				$cache->set( 'weekly_show', $result, USER_CACHE_TTL ) if $result && @$result;
			}

			return $result;
		},
		$params,
		'weekly_show',
		BASE_URL
	);
}

sub _get_weekly_track_infos {
	my ($items, $tracks, $trackIds, $cb) = @_;

	$tracks->{track_id} = join(',', splice(@$trackIds, 0, 50));

	Plugins::Bandcamp::API::get_track_info($tracks, sub {
		my $trackInfo = shift;

		foreach my $show ( @$items ) {
			foreach my $track ( @{ $show->{tracks} }) {
				if (my $details = $trackInfo->{$track->{track_id}}) {
					foreach (qw(downloadable album_id about credits lyrics duration streaming_url)) {
						$track->{$_} ||= $details->{$_} if $details->{$_};
					}
				}
			}
		}
	
		if (scalar @$trackIds) {
			_get_weekly_track_infos($items, $tracks, $trackIds, $cb);
		}
		else {
			$cb->() if $cb;
		}
	});
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

			my $results = $tree->look_down("_tag", "div", "class", "results");
			
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
			
				# add item to get more albums if available
				my $more = $tree->look_down('_tag', 'span', 'class', 'nextprev next');
				
				if ( $more && (my $url = $more->find('a')->attr('href')) ) {
					push @$result, {
						title => 'PLUGIN_BANDCAMP_MORE_MATCHES',
						url   => $args->{tag_url} . '/' . $url,
						type  => 'link',
					}
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

sub get_sales_feed {
	my ($client, $cb, $params) = @_;
	
	main::DEBUGLOG && $log->debug("Getting sales feed");
	
	if ( $params->{use_cache} && (my $cached = $cache->get('sales_feed_' . $client->id)) ) {
		main::DEBUGLOG && $log->debug('found cached api response' . Data::Dump::dump($cached));
		$cb->($cached) if $cb;
		return;
	}
	
	_get($client,
		sub {
			my $items = shift;

			my @albums;
			my %seen;

			foreach my $event (reverse @{$items->{events}}) {
				next unless $event->{event_type} && $event->{event_type} eq 'sale';
				
				foreach ( reverse @{$event->{items}} ) {
					# we only want packages with artwork, albums and tracks
					next unless $_->{item_type} && $_->{item_type} =~ /^[atp]$/ && $_->{art_url};
					
					my $meta = {
						artist => $_->{artist_name},
						title  => $_->{item_description},
						small_art_url => $_->{art_url},
						url    => $_->{band_url} . ($_->{item_slug} || $_->{album_slug}),
					};
					
					if ($_->{item_type} eq 't') {
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

					$meta->{url} = $_->{band_url} . ($_->{album_slug} || $_->{item_slug});
					
					next if $seen{$meta->{url}};
					
					$seen{$meta->{url}} = 1;
					
					push @albums, $meta;
				}
			}
			
			$cache->set('sales_feed_' . $client->id, \@albums, CACHE_TTL * 5);

			$cb->(\@albums) if $cb;
		}, 
		undef,
		$params,
		undef,
		API_URL_SALES . '?start_date=' . (time() - 600),
	);
}

sub get_discovery {
	my ( $client, $cb, $params, $args ) = @_;
	
	my $category = $args->{category};
	my $nocache  = $args->{nocache};
	
	if ( $args->{url} && !$category ) {
		($category) = $args->{url} =~ /s=([a-z]+)/;
	}
	
	my $url = $args->{url} || (DISCOVERY_URL . '?s=' . $category);
	
	if ( !$nocache && (my $cached = $cache->get($url . $client->id)) ) {
		$cb->({
			discography => $cached
		}) if $cb;
		return;
	}
	
	_get(undef, 
		sub {
			my $data = shift;
			
			my $items = [];
			my %genres;
			
			foreach (sort keys %{$data->{discover_payload}}) {
				next unless /s=$category\b/;
				
				my $item = eval { from_json( Encode::encode( 'utf8', $data->{discover_payload}->{$_}) ) };
				
				if ($@) {
					$log->error("Problem parsing JSON data: $@");
				}
				else {
					foreach ( @{$item->{items}} ) {
						next unless $_->{category} && $_->{category} eq $category;
						
						my $large_art = $_->{art_lg_url} || $_->{large_art};

						push @$items, {
							title         => $_->{primary_text},
							artist        => $_->{secondary_text},
							band_id       => $_->{band_id},
							large_art_url => $large_art || $_->{art} || $_->{full_art},
							url           => $_->{url},
						};

						# small artwork version
						if ( $large_art && $_->{art} && $large_art ne $_->{art} ) {
							$cache->set('small_' . $large_art, $_->{art}, META_CACHE_TTL);
						}

						# full size artwork
						if ( $_->{full_art} && $large_art && $_->{full_art} ne $large_art ) {
							$cache->set('full_' . $large_art, $_->{full_art}, META_CACHE_TTL);
						}
					}
					
					if ( $item->{url_args} && !$args->{url} ) {
						foreach ( keys %{$item->{url_args}->{g}} ) {
							$genres{$_} = $item->{url_args}->{g}->{$_};
						}
					}
				}
			}
					
			foreach ( sort keys %genres ) {
				next if /^all$/;
				
				push @$items, {
					title => ucfirst($_),
					url   => DISCOVERY_URL . $genres{$_},
					type  => 'link',
				}
			}
			
			if ( !$nocache && scalar @$items ) {
				$cache->set($url . $client->id, $items, CACHE_TTL);
			}
			
			$cb->({
				discography => $items
			}) if $cb;
		}, 
		undef,
		undef,
		undef,
		$url
	);
}

sub _get {
	my ($client, $cb, $parseCB, $params, $tag, $url) = @_;

	if ( $tag && (my $cached = $cache->get($tag)) ) {
		main::DEBUGLOG && $log->debug("found cached value for '$tag': " . Data::Dump::dump($cached));
		$cb->( $cached );
		return;
	}

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			
			my $result;
			my $error;

			#warn Data::Dump::dump($response->content);
			
			if ( $response->headers->content_type =~ /html/ ) {
				my $tree = HTML::TreeBuilder->new;
				$tree->parse_content( Encode::decode( 'utf8', $response->content) );

				$result = $parseCB->($tree) if $parseCB;

				if (!scalar @$result) {
					$result = [];
				}
			}
			elsif ( $response->headers->content_type =~ /json/ ) {
				$result = decode_json(
					$response->content,
				);
			}
			
			if (!$result) {
				$result = [ 'Error: Invalid data' ];
				$log->error($result->[0]);
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

sub _shall_cache {
	my $params = shift;
	return ( ($params->{isControl} && $params->{index}) || ($params->{isWeb} && defined $params->{index}) ) ? 1 : 0;
}

1;