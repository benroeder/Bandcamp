package Plugins::Bandcamp::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use JSON::XS::VersionOneAndTwo;
use Tie::Cache::LRU;

use Slim::Formats::RemoteMetadata;
use Slim::Menu::GlobalSearch;
use Slim::Menu::TrackInfo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Bandcamp::API;
use Plugins::Bandcamp::Scraper;
use Plugins::Bandcamp::Search;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.bandcamp',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_BANDCAMP',
} );

my $prefs = preferences('plugin.bandcamp');

use constant PLUGIN_TAG       => 'bandcamp';
use constant STREAM_URL_REGEX => qr/(?:bcbits|bandcamp)\.com\/download\/track/i;
use constant IMAGES_URL_REGEX => qr/f0\.bcbits\.com\/(?:img|z)\//;
use constant CACHE_TTL        => 3600 * 12;
use constant MAX_RECENT_ITEMS => 50;
use constant RECENT_CACHE_TTL => 'never';

my $cache = Slim::Utils::Cache->new('bandcamp', 3);

my %recent_plays;
tie %recent_plays, 'Tie::Cache::LRU', MAX_RECENT_ITEMS;

my $does_scrobble;

sub initPlugin {
	my $class = shift;
	
	if (my $username = $prefs->get('username')) {
		$prefs->set('username', '') if $username eq '_bandcamp_';
	}
	
	$prefs->init({
		username => '_bandcamp_'
	});

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
	
	# try to load custom artwork handler - requires recent LMS 7.8 with new image proxy
	eval {
		require Slim::Web::ImageProxy;
		
		# XXX - some might not have updated their 7.8 yet...
		if ( UNIVERSAL::can('Slim::Web::ImageProxy', 'getRightSize') ) {
		
		Slim::Web::ImageProxy->registerHandler(
			match => IMAGES_URL_REGEX,
			func  => sub {
				my ($url, $spec) = @_;
	
				if (my ($art_id) = $url =~ m|f0\.bcbits\.com/img/a(\d+)_|) {
					my $size = Slim::Web::ImageProxy->getRightSize($spec, {
						25 => 22,
						50 => 42,
						100 => 3,
						124 => 8,
						150 => 7,
						210 => 9,
						300 => 4,
						350 => 2,
						700 => 5,
						1024 => 20,
						# 0 => original (size & format, don't use extension)
					}) || '2';
					$url = Plugins::Bandcamp::API::get_artwork_url_from_id($art_id, $size);
				}
				else {
					my $size = Slim::Web::ImageProxy->getRightSize($spec, { 100 => 'small_', 350 => '' }) || 'full_';
					$url = $cache->get("$size$url") || $url;
				}

				return $url;
			},
		);
		main::DEBUGLOG && $log->debug("Successfully registered image proxy for Bandcamp artwork");

		}
	} if preferences('server')->get('useLocalImageproxy');
	
	if (main::WEBUI) {
		require Plugins::Bandcamp::Settings;
		Plugins::Bandcamp::Settings->new();
	}
}

sub getDisplayName { 'PLUGIN_BANDCAMP' }

# don't add this plugin to the Extras menu
sub playerMenu {}


sub handleFeed {
	my ($client, $cb, $args) = @_;
	
	my $params = $args->{params};
	
	my $items = [
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_WEEKLY'),
			type => 'link',
			url  => \&get_weekly_shows,
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_TOPSELLERS'),
			type => 'link',
			url  => \&get_discovery,
			passthrough => [{
				s => 'top'
			}],
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_STAFF_PICKS'),
			type => 'link',
			url  => \&get_discovery,
			passthrough => [{
				s => 'pic' 
			}],
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_NEW_ARRIVALS'),
			type => 'link',
			url  => \&get_discovery,
			passthrough => [{
				s => 'new' 
			}],
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_MOST_RECOMMENDED'),
			type => 'link',
			url  => \&get_discovery,
			passthrough => [{
				s => 'rec',
				r => 'most',
			}],
		},
		{
			name => cstring($client, 'PLUGIN_BANDCAMP_SELLING'),
			type => 'link',
			url  => \&get_selling_items,
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
	];
	
	my $username = $prefs->get('username');
	
	if ($username eq '_bandcamp_') {
		unshift @$items, {
			name => cstring($client, 'PLUGIN_BANDCAMP_FANPAGE'),
			items => [{
				name => cstring($client, 'PLUGIN_BANDCAMP_FAN_MISSING'),
				type => 'textarea',
			}]
		};
	}
	elsif ($username) {
		unshift @$items, {
			name => cstring($client, 'PLUGIN_BANDCAMP_FANPAGE'),
			type => 'link',
			url  => \&get_fan_page,
			passthrough => [{
				fan => $username
			}],
		};
	}
	
	$cb->({
		items => $items,
	});
}

sub get_fan_page {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_fan_page($client,
		sub {
			my $items = shift;
			$items = album_list($client, \&get_item_info_by_url, $items);
			
			# add "Follows" item
			unshift @$items, {
				name  => cstring($client, 'PLUGIN_BANDCAMP_FAN_FOLLOWING', $args->{fan}),
				type  => 'link',
				url   => \&get_fan_following,
				image => __PACKAGE__->_pluginDataFor('icon'),
				passthrough => [ $args ],
			};
			
			$cb->( $items );
		},
		$params,
		$args,
	);
}

sub get_fan_following {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_fan_following($client,
		sub {
			my $items = shift;
			$cb->( artist_list($items) );
		},
		$params,
		$args,
	);
}

sub get_weekly_shows {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::Scraper::get_weekly_shows($client,
		sub {
			my $items = shift;

			my $shows = [];

			foreach my $show (@$items) {
				my $tracks = track_list($client, $show, {
					no_tracknumber => 1,
					artwork        => 1,
					artist         => 1,
				});
				
				push @$shows, {
					name  => $show->{date} . ' - ' . $show->{subtitle},
					line1 => $show->{subtitle},
					line2 => $show->{date},
					image => $show->{large_art_url},
					items => [{
						name => $show->{description},
						type => 'textarea'
					},{
						type => 'playlist',
						name => cstring($client, 'TRACKS'),
						items => $tracks,
						play  => $tracks,
					}]
				};
			}

			$cb->( $shows );
		},
		$params,
	);
}

sub get_discovery {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Bandcamp::Scraper::get_discovery($client,
		sub {
			my $items = shift;
			$cb->( album_list($client, \&get_item_info_by_url, $items, {
				dontSort => 1,
			}) );
		},
		$params,
		$args,
	);
}

sub get_selling_items {
	my ($client, $cb, $params) = @_;
	
	# odd hack to only cache results when entering the menu, but not when drilling down from there
	$params->{use_cache} = ( ($params->{isControl} && $params->{index}) || ($params->{isWeb} && defined $params->{index}) ) ? 1 : 0;
	
	Plugins::Bandcamp::Scraper::get_sales_feed($client,
		sub {
			my $items = shift;
			$cb->( album_list($client, \&get_item_info_by_url, {
				discography => $items,
			}, {
				dontSort => 1,
			}) );
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

			# tell the user when there are tracks which can't be played
			if ( grep { !$_->{streaming_url} } @{$albumInfo->{tracks}} ) {
				push @$items, {
					name => cstring($client, 'PLUGIN_BANDCAMP_NOT_STREAMABLE'),
					type => 'text',
				}
			}
			
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
				large_art_url => $args->{art_lg_url} || $args->{large_art_url},
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
	if ($args->{album_url} =~ m|bandcamp\.com/+tag/.*?\?page=|) {
		get_tag_items($client, $cb, $params, {
			tag_url => $args->{album_url}
		});
	}
	
	# genres inside top/recommendation etc.
	elsif ($args->{album_url} =~ m|bandcamp\.com/discover_cb\?|) {
		get_discovery($client, $cb, $params, {
			url => $args->{url}
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
	
	my $key = Plugins::Bandcamp::API::track_key($url);
	if (my $cached = $cache->get('meta_' . $key)) {
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
		
		my $does_scrobble = _does_scrobble($client);
		
		$meta = {
			title    => $cached->{title},
			artist   => $does_scrobble ? $cached->{artist} : ($cached->{album} . ($cached->{album} ? ' - ' : '') . $cached->{artist}),
			# we'll abuse the album name for the album URL to satisfy the terms of use...
			album    => $does_scrobble ? $cached->{album} : $cached->{album_url},
			duration => $cached->{duration},
			cover    => $cached->{image},
		};
	}
	
	return $meta;
}

sub _does_scrobble {
	my $client = shift;
	
	# check whether user is scrobbling to last.fm - in this case we don't report the artist's url, but real metadata...
	if ( !defined $does_scrobble ) {
		$does_scrobble = 0;
		eval {
			$does_scrobble = preferences('plugin.audioscrobbler')->get('enable_scrobbling') && Slim::Plugin::AudioScrobbler::Plugin->condition();
		};
	}
	
	# scrobbling is globally disabled
	return if !$does_scrobble;
	
	my $_does_scrobble = $client->pluginData('does_scrobble');
	
	return $_does_scrobble if defined $_does_scrobble;
	
	$_does_scrobble = preferences('plugin.audioscrobbler')->client($client)->get('account');
	
	$client->pluginData( 'does_scrobble' => ($_does_scrobble ? 1 : 0) );
	
	return $_does_scrobble;
}

sub trackInfoMenu {
	my ( $client, undef, $track ) = @_;
	
	return unless $client && $track;
	
	my $url = $track->url;
	
	return unless $url && $url =~ STREAM_URL_REGEX;

	my $key = Plugins::Bandcamp::API::track_key($url);
	if (my $cached = $cache->get('meta_' . $key)) {
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
		my $name = $_->{name};
		
		$name .= ' (' . string('PLUGIN_BANDCAMP_FAN') . ')' if $_->{fan};
		
		push @$artists, {
			name  => $name,
			line1 => $_->{offsite_url} ? $name : undef,
			line2 => $_->{offsite_url} || undef,
			url   => $_->{band_id} ? \&get_artist_albums : \&get_fan_page,
			passthrough => [{
				band_id => $_->{band_id},
				fan     => $_->{fan},
			}],
			image => $_->{art_lg_url} || $_->{large_art_url},
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
	my ($client, $cb, $items, $args) = @_;
	
	return [ {
		name => $items->{error},
		type => 'text',
	} ] if $items->{error};
	
	$args ||= {};
	
	my $albums = [];
	
	my @sorted = @{$items->{discography}};
	@sorted = sort { 
		$a->{type} eq 'link' ? 1 
		: (
			$b->{type} eq 'link' ? -1
			: ( lc($a->{title} || $a->{album}) cmp lc($b->{title} || $b->{album}) )
		)
	} @sorted unless $args->{dontSort};

	foreach (@sorted) {
		next unless ref $_ eq 'HASH';
		
		$_->{title} ||= $_->{album};
		$_->{type}  ||= 'playlist';
		
		# special case for the "get more..." item in tags lists
		$_->{title} = cstring($client, $_->{title}) if $_->{title} =~ /PLUGIN_BANDCAMP_/;
		
		push @$albums, {
			name  => $_->{title} . ($_->{artist} ? ' - ' . $_->{artist} : ''),
			line1 => $_->{artist} ? $_->{title} : undef,
			line2 => $_->{artist},
			url   => $cb,
			image => $_->{art_lg_url} || $_->{large_art_url} || $_->{small_art_url} || $_->{image} || __PACKAGE__->_pluginDataFor('icon'),
			passthrough => [{ 
				album_id  => $_->{album_id},
				album_url => $_->{url},
				url       => $_->{url},
				band_id   => $_->{band_id},
				artist    => $_->{artist},
				track_id  => $_->{track_id},
				large_art_url => $_->{art_lg_url} || $_->{large_art_url} || $_->{image},
				tracks    => 1,
			}],
			type  => $_->{type} || 'playlist',
		};
	}

	return [ {
		name => cstring($client, 'EMPTY'),
		type => 'text',
	} ] if !scalar @$albums;
	
	return $albums;
}

sub track_list {
	my ($client, $items, $args) = @_;

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

		my $title = ($track->{streaming_url} ? '' : '* ') . ((defined $track->{number} && !$args->{no_tracknumber}) ? $track->{number} . '. ' : '') . $track->{title};
		push @$tracks, {
#			type  => 'link',
			name  => $title,
			line1 => $args->{artist} && $title,
			line2 => $args->{artist} && $track->{artist},
			play  => $track->{streaming_url},
			image => $args->{artwork} && ($track->{art_lg_url} || $track->{large_art_url}),
			items => $trackinfo,
			on_select   => $track->{streaming_url} ? 'play' : undef,
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