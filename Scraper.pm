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

use constant BASE_URL      => 'https://bandcamp.com/';
use constant TAGS_BASE_URL => BASE_URL . 'tags/';
use constant TAG_BASE_URL  => BASE_URL . 'tag/';
use constant SEARCH_URL    => BASE_URL . 'search?q=';

# not officially documented, but worth moving to the API module?
use constant API_URL_SALES => BASE_URL . 'api/salesfeed/1/get?start_date=';
use constant DISCOVERY_URL => BASE_URL . 'api/discover/3/get_web?p=0&';

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

sub get_album_info {
	my ($client, $cb, $params, $args) = @_;

	my $album_url = $args->{album_url} || $args->{url};

	main::INFOLOG && $log->info("Getting tracks for album: $album_url");

	_get($client,
		sub {
			my $items = shift;

			my $album = shift @$items;

			if ( ref $album && !$album->{tracks} && $album->{name} && $album->{name} =~ /error.*404/i ) {
				$album = {
					error => Slim::Utils::Strings::cstring($client, 'PLUGIN_BANDCAMP_ALBUM_NOT_FOUND')
				};
			}

			# we had to squeeze the full album object into an array ref, because that's what the scraping code expects...
			$cb->($album) if $cb;
		},
		sub {
			my $tree   = shift;
			my $result = [];

			my $section = $tree->look_down("_tag", "div", "id", "pgBd");

			if ($section) {
				my @scripts = $section->look_down("_tag", "script");
				foreach (@scripts) {
					my $html = $_->as_HTML;

					if ($html =~ /var TralbumData\b/ && $html =~ /var EmbedData\b/ && $html =~ /^\s+trackinfo: (\[.*\]),\s*$/m) {
						my $trackData = eval { from_json( Encode::encode('utf8', $1) ) };
						my $album = {
							url => $album_url
						};

						# if we found track data, we'll continue
						if ( $trackData && ref $trackData ) {
							if ( $html =~ /var EmbedData = (\{.*?\});/s ) {
								my $albumData = Encode::encode('utf8', $1);

								if ($albumData =~ /album_title: "(.*?)"/) {
									$album->{title} = $1;
								}

								if ($albumData =~ /artist: "(.*?)"/) {
									$album->{artist} = $1;
								}

								if ($albumData =~ /art_id: (\d+)/) {
									$album->{art_lg_url} = Plugins::Bandcamp::API::get_artwork_url_from_id($1);
								}
							}

							if ( $html =~ /^\s+current: (\{.*\}),\s*$/m ) {
								my $moreData = eval { from_json( Encode::encode('utf8', $1) ) };

								if ( $moreData && ref $moreData ) {
									$album->{about} = $moreData->{about} if $moreData->{about};
									$album->{band_id} = $moreData->{band_id} if $moreData->{band_id};
									$album->{credits} = $moreData->{credits} if $moreData->{credits};
									$album->{art_lg_url} ||= Plugins::Bandcamp::API::get_artwork_url_from_id($moreData->{art_id}) if $moreData->{art_id};
									$album->{release_date} = $moreData->{release_date} if $moreData->{release_date};
								}
							}

							if ( $html =~ /^\s+packages: (\[.*\]),\s*$/m ) {
								my $moreData = eval { from_json( Encode::encode('utf8', $1) ) };

								if ( $moreData && ref $moreData && (my ($item) = grep { $_->{album_id} } @$moreData) ) {
									$album->{album_id} ||= $item->{album_id};
								}
							}
						}

						$album->{tracks} = [ map {
							$_->{number} = $_->{track_num};
							$_->{streaming_url} = $_->{file};
							Plugins::Bandcamp::API::cache_track_info($_, $album);
						} @$trackData ];

						$result = [$album];
					}
				}
			}

			$cache->set( $album_url, $result, USER_CACHE_TTL ) if scalar @$result;

			return $result;
		},
		$params,
		$album_url,
		$album_url
	);
}

sub get_fan_page {
	my ( $client, $cb, $params, $args ) = @_;

	my $fan = $args->{fan} || '';

	main::DEBUGLOG && $log->debug("Getting fan page for: $fan");

	my $cache_key = "fanpage/$fan";

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = {};

			my $collection = $tree->look_down("_tag", "div", "id", "pagedata");

			if ($collection) {
				my $data = $collection->attr('data-blob');

				$data = eval { from_json( Encode::encode( 'utf8', $data) ) };

				if ($@ || !$data) {
					$log->error($@);
				}
				else {
					# extract the fan_id if possible
					if ( (my $fan_data = $data->{fan_data}) && (my $fan = $args->{fan}) ) {
						if ( my $fan_id = $fan_data->{fan_id} ) {
							main::INFOLOG && $log->info("Caching Fan ID for '$fan': $fan_id");
							$cache->set('user_id_' . $fan, $fan_id, META_CACHE_TTL);
						}
					}

					if ( my $items = $data->{item_cache} ) {
						foreach my $type ( qw(collection wishlist) ) {
							if ( $items->{$type} && ref $items->{$type} && keys %{$items->{$type}} ) {
								$result->{$type} = [ sort {
									uc($a->{title}) cmp uc($b->{title})
								} @{ Plugins::Bandcamp::API::parse_album_list([ values %{$items->{$type}} ]) } ];
							}
						}

						foreach my $type ( qw(following_bands following_fans followers) ) {
							if ( $items->{$type} && ref $items->{$type} && keys %{$items->{$type}} ) {
								$result->{$type} = [ sort {
									uc($a->{name}) cmp uc($b->{name})
								}  @{ Plugins::Bandcamp::API::parse_artist_list([ values %{$items->{$type}} ]) } ];
							}
						}
					}
				}
			}

			$cache->set( $cache_key, $result, USER_CACHE_TTL ) if keys %$result; # && _shall_cache($params);

			return [$result];
		},
		$params,
		$cache_key,
		BASE_URL . $fan
	);
}

=pod replaced with API::get_weekly_shows
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
=cut

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

sub search_fans {
	my ( $client, $cb, $args ) = @_;

	my $search = $args->{search};
	my $params = $args->{params};

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];

			my @fans = $tree->look_down("_tag", "li", "class", qr/searchresult fan/);

			foreach my $fan (@fans) {
				if ($fan) {
					my $fan_item = {};

					my $fan_details = $fan->look_down("_tag", "div", "class", "heading");
					foreach ($fan_details->content_list) {
						next unless blessed($_) && $_->attr('href') =~ /bandcamp\.com/ && ref $_->content eq 'ARRAY';

						$fan_item->{name} = $_->content->[0];
						$fan_item->{name} =~ s/^\s*|\s*$//g;

						$fan_item->{offsite_url} = $_->attr('href');
						$fan_item->{offsite_url} =~ s/\?.*//;

						if ( $fan_item->{offsite_url} =~ m|([^/]+$)| ) {
							$fan_item->{fan} = $1;
						}
					}

					if ( my $fan_img = $fan->look_down("_tag", "img") ) {
						$fan_item->{art_lg_url} = $fan_img->attr('src');
					}

					push @$result, $fan_item;
				}
			}

			$cache->set( 'fan_list' . $search, $result, CACHE_TTL ) if @$result;

			return $result;
		},
		$params,
		'fan_list' . $search,
		SEARCH_URL . $search,
	);
}

sub search {
	my ( $client, $cb, $args ) = @_;

	my $search = $args->{search};
	my $params = $args->{params};

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];

			my @items = $tree->look_down("_tag", "li", "class", qr/searchresult (?:track|album|band)/);

			foreach my $item (@items) {
				my $class = $item->attr('class');
				if ($class =~ /\btrack\b/) {
					my $track_item = {};

					my $track_details = $item->look_down("_tag", "div", "class", "heading");
					foreach ($track_details->content_list) {
						next unless blessed($_) && $_->attr('href') =~ /bandcamp\.com/ && ref $_->content eq 'ARRAY';

						$track_item->{name} = $_->content->[0];
						$track_item->{name} =~ s/^\s*|\s*$//g;

						$track_item->{offsite_url} = $_->attr('href');

						if ( $track_item->{offsite_url} =~ m|search_item_id=(\d+)| ) {
							$track_item->{track_id} = $1;
						}

						$track_item->{offsite_url} =~ s/\?.*//;

						next unless $track_item->{track_id};
					}

					if ( my $track_artist = $item->look_down("_tag", "div", "class", "subhead") ) {
						$track_item->{artist} = $track_artist->content->[0];
						$track_item->{artist} =~ s/.* by (.*?)/$1/;
						$track_item->{artist} =~ s/^\s*|\s*$//g;
					}

					if ( my $track_img = $item->look_down("_tag", "img") ) {
						$track_item->{art_lg_url} = $track_img->attr('src');
						$track_item->{art_lg_url} =~ s/_7\./_5./;
					}

					push @$result, $track_item;
				}
				elsif ($class =~ /\balbum\b/) {
					my $album_item = {};

					my $album_details = $item->look_down("_tag", "div", "class", "heading");
					foreach ($album_details->content_list) {
						next unless blessed($_) && $_->attr('href') =~ /bandcamp\.com/ && ref $_->content eq 'ARRAY';

						$album_item->{album} = $_->content->[0];
						$album_item->{album} =~ s/^\s*|\s*$//g;

						$album_item->{album_url} = $_->attr('href');

						if ( $album_item->{album_url} =~ m|search_item_id=(\d+)| ) {
							$album_item->{album_id} = $1;
						}

						$album_item->{album_url} =~ s/\?.*//;
						$album_item->{url} = $album_item->{album_url};

						next unless $album_item->{album_id};
					}

					if ( my $album_artist = $item->look_down("_tag", "div", "class", "subhead") ) {
						$album_item->{artist} = $album_artist->content->[0];
						$album_item->{artist} =~ s/^ by //;
						$album_item->{artist} =~ s/^\s*|\s*$//g;
					}

					if ( my $album_img = $item->look_down("_tag", "img") ) {
						$album_item->{art_lg_url} = $album_img->attr('src');
					}

					push @$result, $album_item;
				}
				elsif ($class =~ /\bband\b/) {
					push @$result, _parse_band_element($item);
				}
			}

			$cache->set( 'search_list' . $search, $result, CACHE_TTL ) if @$result;

			return $result;
		},
		$params,
		'search_list' . $search,
		SEARCH_URL . $search,
	);
}

sub search_artists {
	my ( $client, $cb, $args ) = @_;

	my $search = $args->{search};
	my $params = $args->{params};

	_get($client,
		$cb,
		sub {
			my $tree   = shift;
			my $result = [];

			foreach ( $tree->look_down("_tag", "li", "class", qr/searchresult band/) ) {
				if ($_) {
					push @$result, _parse_band_element($_);
				}
			}

			$cache->set( 'artist_list' . $search, $result, CACHE_TTL ) if @$result;

			return $result;
		},
		$params,
		'artist_list' . $search,
		SEARCH_URL . $search,
	);
}

sub _parse_band_element {
	my $band = shift;
	my $band_item = {};

	my $band_details = $band->look_down("_tag", "div", "class", "heading");
	foreach ($band_details->content_list) {
		next unless blessed($_) && $_->attr('href') =~ /bandcamp\.com/ && ref $_->content eq 'ARRAY';

		$band_item->{name} = $_->content->[0];
		$band_item->{name} =~ s/^\s*|\s*$//g;

		$band_item->{offsite_url} = $_->attr('href');

		if ( $band_item->{offsite_url} =~ m|search_item_id=(\d+)| ) {
			$band_item->{band_id} = $1;
		}

		$band_item->{offsite_url} =~ s/\?.*//;

		next unless $band_item->{band_id};
	}

	if ( my $band_img = $band->look_down("_tag", "img") ) {
		$band_item->{art_lg_url} = $band_img->attr('src');
	}

	return $band_item;
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

					my $img = $_->look_down('_tag', 'div', 'class', 'tralbum-art-container art artHidden')->attr('onclick');
					if ($img) {
						$img =~ /.*(http.*)\).*/;
						$img = $1 || '';
					}

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

					my $uri = URI->new($args->{tag_url});
					my $params = $uri->query_form_hash;
					delete $params->{page};

					my $pageUri = URI->new($url);

					foreach (keys %{ $pageUri->query_form_hash }) {
						$params->{$_} = $pageUri->query_form_hash->{$_};
					}
					$uri->query_form( %$params );

					$url = $uri->as_string;
					$url = BASE_URL . $url if $url =~ m|^/|;

					push @$result, {
						title => 'PLUGIN_BANDCAMP_MORE_MATCHES',
						url   => $url,
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
		main::DEBUGLOG && $log->is_debug && $log->debug('found cached api response' . Data::Dump::dump($cached));
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
					next unless $_->{item_type} && $_->{item_type} =~ /^[atp]$/;

					my $meta = {
						artist => $_->{artist_name},
						title  => $_->{item_description},
						large_art_url => Plugins::Bandcamp::API::get_complete_url($_->{art_url}) || Plugins::Bandcamp::API::get_artwork_url_from_id($_->{art_id}),
						url    => Plugins::Bandcamp::API::get_complete_url($_->{url}) || Plugins::Bandcamp::API::get_url_from_hints($_->{url_hints}),
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
		API_URL_SALES . (time() - 600),
	);
}

sub get_discovery {
	my ( $client, $cb, $params, $args ) = @_;

	my $nocache  = delete $args->{nocache};
	my $url      = delete $args->{url};
	my $orig_url = $url;

	if ( $url && !$args->{s} ) {
		($args->{s}) = $url =~ /s=([a-z]+)/;
	}

	$url ||= DISCOVERY_URL . join('&', map { "$_=" . $args->{$_} } keys %$args);

	if ( !$nocache && (my $cached = $cache->get($url . ($client ? $client->id : ''))) ) {
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

			foreach ( @{$data->{items}} ) {
				my $large_art = $_->{art_lg_url} || $_->{large_art};

				push @$items, {
					title         => $_->{primary_text},
					artist        => $_->{secondary_text},
					band_id       => $_->{band_id},
					large_art_url => $large_art || $_->{art} || $_->{full_art} || Plugins::Bandcamp::API::get_artwork_url_from_id($_->{art_id}),
					url           => $_->{url} || Plugins::Bandcamp::API::get_url_from_hints($_->{url_hints}),
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

			if ( $data->{args} && !$orig_url && ref $data->{args}->{g} ) {
				while ( my ($k, $v) = each %{$data->{args}->{g}} ) {
					$genres{$k} = $v;
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
				$cache->set($url . ($client ? $client->id : 'xxx'), $items, CACHE_TTL);
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
		main::INFOLOG && $log->is_info && $log->info("found cached value for '$tag': ");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		$cb->( $cached );
		return;
	}

	$url = BASE_URL . $url if $url =~ m|^/|;

	main::INFOLOG && $log->is_info && $log->info("GETting $url");

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

			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

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

# sub _shall_cache {
# 	my $params = shift;
# 	return ( ($params->{isControl} && $params->{index}) || ($params->{isWeb} && defined $params->{index}) ) ? 1 : 0;
# }

1;