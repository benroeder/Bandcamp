package Plugins::Bandcamp::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use JSON::XS::VersionOneAndTwo;
use Tie::Cache::LRU;

use Slim::Formats::RemoteMetadata;
use Slim::Menu::GlobalSearch;
use Slim::Menu::TrackInfo;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Bandcamp::API;
use Plugins::Bandcamp::Scraper;
use Plugins::Bandcamp::Search;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.bandcamp',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_BANDCAMP',
} );

use constant PLUGIN_TAG       => 'bandcamp';
use constant STREAM_URL_REGEX => qr/bandcamp\.com\/download\/track/i;
use constant CACHE_TTL        => 3600 * 12;
use constant MAX_RECENT_ITEMS => 50;
use constant RECENT_CACHE_TTL => 60*60*24*365;

my $cache = Slim::Utils::Cache->new('plugin_bandcamp', 2);

my %recent_plays;
tie %recent_plays, 'Tie::Cache::LRU', MAX_RECENT_ITEMS;

sub initPlugin {
	my $class = shift;

	Plugins::Bandcamp::API::init( $cache, $class->_pluginDataFor('dk') );	
	Plugins::Bandcamp::Scraper::init( $cache );	
	Plugins::Bandcamp::Search::init( $cache );	
	
	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => PLUGIN_TAG,
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
	
	Slim::Formats::RemoteMetadata->registerProvider(
		match => STREAM_URL_REGEX,
		func  => \&metadata_provider,
	);
	
	# Track Info item
	Slim::Menu::TrackInfo->registerInfoProvider( bandcamp => (
		after => 'moreinfo',
		func  => \&trackInfoMenu,
	) );
	
	Slim::Menu::GlobalSearch->registerInfoProvider( bandcamp => (
		before => 'middle',
		func   => sub {
			my ( $client, $tags ) = @_;
			
			my $searchParam = $tags->{search};
			my $passthrough = [{ q => $searchParam }];

			return [{
				name  => cstring($client, 'PLUGIN_BANDCAMP'),
				items => [{
					name        => cstring($client, 'SEARCHFOR_ARTISTS'),
					url         => \&Plugins::Bandcamp::Search::search_artists,
					passthrough => $passthrough,
					searchParam => $searchParam,
				},{
					name        => cstring($client, 'PLUGIN_BANDCAMP_SEARCHFOR_TAGS'),
					url         => \&Plugins::Bandcamp::Search::search_tags,
					passthrough => $passthrough,
					searchParam => $searchParam,
				}]
			}]
		},
	) );
	
	# initialize recent plays: need to add them to the LRU cache ordered by timestamp
	my $recent_plays = $cache->get('recent_plays');
	map {
		$recent_plays{$_} = $recent_plays->{$_};
	} sort { 
		$recent_plays->{$a}->{ts} <=> $recent_plays->{$a}->{ts} 
	} keys %$recent_plays;
}

sub getDisplayName { 'PLUGIN_BANDCAMP' }

# don't add this plugin to the Extras menu
sub playerMenu {}


sub handleFeed {
	my ($client, $cb, $args) = @_;
	
	my $params = $args->{params};
	
	$cb->({
		items => [
			{
				name => cstring($client, 'PLUGIN_BANDCAMP_TOPSELLERS'),
				type => 'link',
				url  => \&get_top_sellers,
			},
			{
				name => cstring($client, 'PLUGIN_BANDCAMP_FEATURED_ALBUM'),
				type => 'link',
				url  => \&get_featured_album,
			},
			{
				name  => cstring($client, 'PLUGIN_BANDCAMP_RECENTLY_PLAYED'),
				type => 'link',
				url  => \&recently_played,
			},
			{
				name => cstring($client, 'GENRES'),
				type => 'link',
				url  => \&get_tags,
			},
			{
				name => cstring($client, 'PLUGIN_BANDCAMP_LOCATIONS'),
				type => 'link',
				url  => \&get_locations,
			},
			{
				name  => cstring($client, 'SEARCH'),
				type => 'search',
				url  => \&Plugins::Bandcamp::Search::search
			},
			{
				name => cstring($client, 'RECENT_SEARCHES'),
				type => 'link',
				url  => \&Plugins::Bandcamp::Search::recent_searches,
			}
		],
	});
}

sub get_top_sellers {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::Scraper::get_top_sellers($client,
		sub {
			my $items = shift;
			$cb->( album_list($client, \&get_item_info_by_url, $items) );
		},
		$params,
	);
}

sub get_featured_album {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::Scraper::get_featured_album($client,
		sub {
			my $items = shift;
			
			my $item   = $items->[0];

			my $result = album_list($client, \&get_item_info_by_url, {
				discography => [ $item ]
			});

			push @$result, {
				name => cstring($client, 'PLUGIN_BANDCAMP_REVIEW'),
				items => [{
					name => _cleanup_multiline($item->{review}),
					type => 'text',
					wrap => 1,
				}]
			} if $item->{review};
			
			push @$result, {
				name => $item->{header},
				type => 'text',
			} if $item->{header};

			$cb->( $result );
		},
		$params,
	);
}

sub recently_played {
	my ($client, $cb, $params) = @_;

	my $items = [ 
		sort { lc($a->{title}) cmp lc($b->{title}) } 
		map { $recent_plays{$_} } 
		grep { $recent_plays{$_} }
		keys %recent_plays 
	];

	$items = album_list($client, \&get_item_info_by_url, {
		discography => $items
	});
	
	$cb->({
		items => $items
	});
}

sub get_tags {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::Scraper::get_tag_list($client,
		sub {
			my $items = shift;
			$cb->( tag_list([ grep { $_->{cloud} eq 'tags_cloud' } @$items ]) );
		},
		$params,
	);
}

sub get_locations {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::Scraper::get_tag_list($client,
		sub {
			my $items = shift;
			$cb->( tag_list([ grep { $_->{cloud} eq 'locations_cloud' } @$items ]) );
		},
		$params,
	);
}

sub get_tag_items {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_tag_items($client,
		sub {
			my $items = shift;
			$cb->( album_list($client, \&get_item_info_by_url, $items) );
		},
		$params,
		$args,
	);
}

sub get_artist_albums {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Bandcamp::API::get_artist_albums($client, 
		sub {
			my $items = shift;

			$cb->( album_list($client, 
				sub {
					my ($client, $cb, $params, $args) = @_;
					if ($args->{album_id}) {
						get_album($client, $cb, $params, $args);
					}
					else {
						get_track($client, $cb, $params, $args);
					}
				},
				$items
			), @_ );
		}, 
		$params, 
		$args
	);
}

sub get_album {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Bandcamp::API::get_album_info($client,
		sub {
			my $albumInfo = shift;

			$log->error( Data::Dump::dump($albumInfo) ) if ref $albumInfo ne 'HASH';
			
			return [ {
				name => $albumInfo->{error},
				type => 'text',
			} ] if $albumInfo->{error};

			$albumInfo->{artist} ||= $args->{artist};

			my $items = [];

			push @$items, {
				name => (
					cstring($client, $albumInfo->{downloadable} 
						? ($albumInfo->{downloadable} == 1 ? 'PLUGIN_BANDCAMP_FREE' : 'PLUGIN_BANDCAMP_PAID')
						: 'PLUGIN_BANDCAMP_NO_DOWNLOAD'
					)
				),
				type => 'text',
			},
			{
				name => $albumInfo->{url},
				type => 'text',
				weblink => $albumInfo->{url},
			} if ($albumInfo->{downloadable} && $albumInfo->{url});

			push @$items, {
				name => cstring($client, 'PLUGIN_BANDCAMP_ABOUT'),
				items => [{
					name => _cleanup_multiline($albumInfo->{about}),
					type => 'text',
					wrap => 1,
				}]
			} if $albumInfo->{about};
			
			push @$items, {
				name => cstring($client, 'PLUGIN_BANDCAMP_CREDITS'),
				items => [{
					name => _cleanup_multiline($albumInfo->{credits}),
					type => 'text',
					wrap => 1,
				}]
			} if $albumInfo->{credits};
			
			push @$items, @{ track_list($client, $albumInfo) };
			
			$cb->( $items, @_ );
		},
		$params,
		$args
	);
}

sub get_track {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::API::get_track_info($args,
		sub {
			my $items = shift;
			
			$items = track_list($client, {
				tracks => [ $items ],
				artist => $args->{artist},
				url    => $args->{album_url},
				large_art_url => $args->{large_art_url},
			});

			# sometimes we only want the track-information, but not the track itself			
			if ($args->{notracks} && $items && ref $items eq 'ARRAY' && $items->[0] && ref $items->[0] eq 'HASH' && $items->[0]->{items}) {
				$items = $items->[0]->{items};
			}
			
			$cb->({
				items => $items,
			}, @_ );
		},
	)	
}

sub get_item_info_by_url {
	my ($client, $cb, $params, $args) = @_;
	
	# "Get more..." link
	if ($args->{album_url} =~ m|bandcamp\.com/tag/.*?/\?page=|) {
		get_tag_items($client, $cb, $params, {
			tag_url => $args->{album_url}
		});
	}
	else {
		Plugins::Bandcamp::API::get_item_info_by_url($client,
			sub {
				my ($items) = shift;
				
				if ($items->{album_id}) {
					$args->{album_id} ||= $items->{album_id};
					
					get_album($client, $cb, $params, $args);
				}
				else {
					$args->{track_id}  ||= $items->{track_id};
					$args->{album_url} ||= $args->{url};
					
					get_track($client, $cb, $params, $args);
				}
			},
			$params,
			$args,
		);
	}
}

# helper methods for metadata and trackinfo
sub metadata_provider {
	my ( $client, $url ) = @_;

	my $meta = {
		title => Slim::Music::Info::getCurrentTitle(shift),
		cover  => __PACKAGE__->_pluginDataFor('icon'),
	};
	
	if (my $cached = $cache->get('meta_' . $url)) {
		if ($cached->{album_url}) {
			my $song = $client->playingSong();

			# keep track of the albums we're playing
			if ( (my $title = ($cached->{album} || $cached->{title})) && $song && $song->track->url eq $url ) {
				$recent_plays{$title} = {
					title    => $title,
					url      => $cached->{album_url},
					artist   => $cached->{artist},
					image    => $cached->{image},
					album_id => $cached->{album_id},
					ts       => time(),
				};
				
				$cache->set('recent_plays', \%recent_plays, RECENT_CACHE_TTL);
			}
			
			$cached->{album_url} =~ s/\?pk=.*//;
		}
		
		$meta = {
			title    => $cached->{title},
			artist   => $cached->{album} . ($cached->{album} ? ' - ' : '') . $cached->{artist},
			# we'll abuse the album name for the album URL to satisfy the terms of use...
			album    => $cached->{album_url},
			duration => $cached->{duration},
			cover    => $cached->{image},
#			bitrate  => '128k CBR',
#			type     => 'MP3 (bandcamp.com)',
#			icon     => __PACKAGE__->getIcon(),
		};
#	warn Data::Dump::dump($cached);
	}
	
#	warn Data::Dump::dump($meta);
	
	return $meta;
}

sub trackInfoMenu {
	my ( $client, undef, $track ) = @_;
	
	return unless $client && $track;
	
	my $url = $track->url;
	
	return unless $url && $url =~ STREAM_URL_REGEX;

	if (my $cached = $cache->get('meta_' . $url)) {
		$cached->{large_art_url} = $cached->{image};
		$cached->{notracks}      = 1;
		
		return {
			type => 'link',
			name => cstring($client, 'PLUGIN_FROM_BANDCAMP'),
			url  => \&get_track,
			passthrough => [ $cached ],
		};
	}
	
	return;
}


# methods creating the lists to be shown from our data
sub artist_list {
	my $items = shift;
	
	return [ {
		name => $items->{error},
		type => 'text',
	} ] if $items->{error};
	
	my $artists = [];
	foreach (@{$items->{results}}) {
		push @$artists, {
			name  => $_->{name},
			line1 => $_->{offsite_url} ? $_->{name} : undef,
			line2 => $_->{offsite_url} || undef,
			url   => \&get_artist_albums,
			passthrough => [{
				band_id => $_->{band_id},
			}],
			type  => 'link',
		}
	}
	
	return $artists;
}

sub tag_list {
	my $items = shift;
	
	my $results = [];
	
	$items = [ sort { uc($a->{name}) cmp uc($b->{name}) } @$items ];
	
	foreach my $item ( @$items ) {
		push @$results, {
			name => $item->{name},
			textkey => substr( uc($item->{name}), 0, 1 ),
			url  => \&get_tag_items,
			type => 'link',
			passthrough => [ { tag_url => $item->{url} } ]
		}
	}
	
	return $results;
}

sub album_list {
	my ($client, $cb, $items) = @_;
	
	return [ {
		name => $items->{error},
		type => 'text',
	} ] if $items->{error};
	
	my $albums = [];
	foreach (@{$items->{discography}}) {
		next unless ref $_ eq 'HASH';
		
		my $type = 'playlist';

		$_->{title} ||= $_->{album};
		
		# special case for the "get more..." item in tags lists
		if ( $_->{title} eq 'PLUGIN_BANDCAMP_MORE_MATCHES' ) {
			$_->{title} = cstring($client, $_->{title}),
			$type = 'link',
		}
		
		push @$albums, {
			name  => $_->{title} . ($_->{artist} ? ' - ' . $_->{artist} : ''),
			line1 => $_->{artist} ? $_->{title} : undef,
			line2 => $_->{artist},
			url   => $cb,
			image => $_->{large_art_url} || $_->{image},
			passthrough => [{ 
				album_id  => $_->{album_id},
				album_url => $_->{url},
				url       => $_->{url},
				band_id   => $_->{band_id},
				artist    => $_->{artist},
				track_id  => $_->{track_id},
				large_art_url => $_->{large_art_url} || $_->{image},
				tracks    => 1,
			}],
			type  => $type,
		};
	}

	return [ {
		name => cstring($client, 'EMPTY'),
		type => 'text',
	} ] if !scalar @$albums;
	
	return $albums;
}

sub track_list {
	my ($client, $items) = @_;

	my $tracks = [];
	foreach my $track (@{$items->{tracks}}) {
		$track = Plugins::Bandcamp::API::cache_track_info($track, $items);
		
		my $trackinfo = [];

		push @$trackinfo, {
			name => (
				cstring($client, $track->{downloadable} 
					? ($track->{downloadable} == 1 ? 'PLUGIN_BANDCAMP_FREE' : 'PLUGIN_BANDCAMP_PAID')
					: 'PLUGIN_BANDCAMP_NO_DOWNLOAD'
				)
			),
			type => 'text',
		} if ($track->{downloadable} && $track->{url} && $track->{url} =~ /^http/);

		push @$trackinfo, {
			name => $track->{url},
			type => 'text',
			weblink => $track->{url},
		} if ($track->{url} && $track->{url} =~ /^http/);
		
		push @$trackinfo, {
			type => 'link',
			name => cstring($client, 'ARTIST') . cstring($client, 'COLON') . ' ' . $track->{artist},
			url  => \&get_artist_albums,
			passthrough => [{
				band_id => $track->{band_id}
			}]
		} if $track->{artist};
		
		push @$trackinfo, {
			type => 'link',
			name => $track->{album} 
						? cstring($client, 'ALBUM') . cstring($client, 'COLON') . ' ' . $track->{album} 
						: cstring($client, 'PLUGIN_BANDCAMP_OTHER_TRACKS'),
			url  => \&get_album,
			passthrough => [{
				album_id => $track->{album_id},
				tracks   => 1,
			}]
		} if $track->{album_id};

		push @$trackinfo, {
			name => cstring($client, 'PLUGIN_BANDCAMP_ABOUT'),
			items => [{
				name => _cleanup_multiline($track->{about}),
				type => 'text',
				wrap => 1,
			}]
		} if $track->{about};
		
		push @$trackinfo, {
			name => cstring($client, 'PLUGIN_BANDCAMP_CREDITS'),
			items => [{
				name => _cleanup_multiline($track->{credits}),
				type => 'text',
				wrap => 1,
			}]
		} if $track->{credits};
		
		push @$trackinfo, {
			name => cstring($client, 'PLUGIN_BANDCAMP_LYRICS'),
			items => [{
				name => _cleanup_multiline($track->{lyrics}),
				type => 'text',
				wrap => 1,
			}]
		} if $track->{lyrics};

		push @$trackinfo, {
			name => cstring($client, 'LENGTH') . cstring($client, 'COLON') . ' ' . sprintf('%s:%02s', int($track->{duration} / 60), $track->{duration} % 60),
			type => 'text',
		} if $track->{duration};

		push @$tracks, {
#			type  => 'link',
			name  => (defined $track->{number} ? $track->{number} . '. ' : '') . $track->{title},
			play  => $track->{streaming_url},
			#image => $track->{large_art_url},
			items => $trackinfo,
			on_select   => 'play',
			playall     => 1,
			passthrough => [{
				track_id => $track->{track_id}
			}]
		};
	}
	
	return $tracks;
}


sub _cleanup_multiline {
	my $text = shift;
	
	return unless defined $text;
	
	$text =~ s/\r\n/\n/g;	
	return $text;
}

1;