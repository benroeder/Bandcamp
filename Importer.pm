package Plugins::Bandcamp::Importer;

use strict;

# can't "use base ()", as this would fail in LMS 7
BEGIN {
	eval {
		require Slim::Plugin::OnlineLibraryBase;
		our @ISA = qw(Slim::Plugin::OnlineLibraryBase);
	};
}

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);

my $log = logger('plugin.bandcamp');
my $cache;

sub initPlugin {
	my $class = shift;

	if (!CAN_IMPORTER) {
		$log->warn('The library importer feature requires at least Logitech Media Server 8.');
		return;
	}

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class) || return;

	require Plugins::Bandcamp::API::Sync;
	$cache = Plugins::Bandcamp::API::Sync->init($pluginData);

	$class->SUPER::initPlugin(@_)
}

# TODO - remove!
sub isImportEnabled { 1 }

sub startScan { if (main::SCANNER) {
	my $class = shift;

	$class->initOnlineTracksTable();

	if (!Slim::Music::Import->scanPlaylistsOnly()) {
		$class->scanAlbums();
		# $class->scanArtists();
	}

	# $class->scanPlaylists();

	$class->deleteRemovedTracks();

	Slim::Music::Import->endImporter($class);
} };

sub scanAlbums {
	my ($class) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_bandcamp_albums',
		'total' => 1,
		'every' => 1,
	});

	my @missingAlbums;

	main::INFOLOG && $log->is_info && $log->info("Reading albums...");
	$progress->update(string('PLUGIN_BANDCAMP_PROGRESS_READ_ALBUMS'));

	my $albums = Plugins::Bandcamp::API::Sync->myAlbums();
	$progress->total(scalar @$albums);

	# $cache->set('latest_album_update', $class->libraryMetaId($libraryMeta), time() + 360 * 86400);

	my @albums;

	foreach my $album (@$albums) {
		my $albumDetails = $cache->get('album_with_tracks_' . $album->{id});

		if ($albumDetails && $albumDetails->{tracks} && ref $albumDetails->{tracks}) {
			$progress->update($album->{title});
			$class->storeTracks([
				grep { $_ } map { _prepareTrack($album, $_, $albumDetails->{about}) } @{ $albumDetails->{tracks} }
			]);

			main::SCANNER && Slim::Schema->forceCommit;
		}
		else {
			push @missingAlbums, $album->{id};
		}
	}

	foreach my $albumId (@missingAlbums) {
		my $album = Plugins::Bandcamp::API::Sync->getAlbum($albumId);
		$progress->update($album->{title});

		next unless $album && ref $album && $album->{tracks} && scalar @{$album->{tracks}};

		$cache->set('album_with_tracks_' . $albumId, $album, time() + 86400 * 90);

		$class->storeTracks([
			grep { $_ } map { _prepareTrack($album, $_, $album->{about}) } @{ $album->{tracks} }
		]);

		main::SCANNER && Slim::Schema->forceCommit;
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
}

sub _prepareTrack {
	my ($album, $track, $comment) = @_;

	return unless $track && $track->{streaming_url};

	my $url = sprintf('bandcamp://%s.mp3', $track->{track_id});

	my $attributes = {
		url          => $url,
		TITLE        => $track->{title},
		ARTIST       => $album->{artist},
		ARTIST_EXTID => 'bandcamp:artist:' . $album->{artist_id},
		# TRACKARTIST  => $track->{performer}->{name},
		ALBUM        => $album->{title},
		ALBUM_EXTID  => 'bandcamp:album:' . $album->{id},
		TRACKNUM     => $track->{number},
		# GENRE        => $album->{genre},
		SECS         => $track->{duration},
		# YEAR         => (localtime($album->{released_at}))[5] + 1900,
		COVER        => $album->{cover},
		AUDIO        => 1,
		EXTID        => $url,
		# TODO - parse timestamp!
		# TIMESTAMP    => $album->{added},
		CONTENT_TYPE => 'mp3',
		SAMPLERATE   => 128_000,
		COMMENT      => $comment,
	};

	return $attributes;
}

# latest album
# curl --location --request POST 'https://bandcamp.com/api/fancollection/1/wishlist_items' \
# --header 'Content-Type: application/json' \
# --header 'Cookie: client_id=EC2FF8F471A0EB0915984425A5C0FA23879576ADFC9FF65111280186E58E08C7; fan_visits=10236; BACKENDID=bender24-4' \
# --data-raw '{
#   "fan_id": 10236,
#   "older_than_token": "1606494993:1603563167:a::",
#   "count": 1
# }'

# Collection summary
# curl --location --request GET 'https://bandcamp.com/api/fan/2/collection_summary' \
# --header 'Cookie: client_id=EC2FF8F471A0EB0915984425A5C0FA23879576ADFC9FF65111280186E58E08C7; fan_visits=10236; BACKENDID=bender24-4; session=1%09t%3A1606491461%09bp%3A1%09r%3A%5B%22322845039c10236a34939844x1606495375%22%2C%22364587321a34939844c0x1606494947%22%2C%22365547591x0a34939844x1606494866%22%5D; identity=7%0958IhReMTODjIDcbKQHKEZ415UpCJ7oFBne8qAupDu5g%3D%09%7B%22ex%22%3A0%2C%22id%22%3A1712700664%7D'

# get playback URL
# curl --location --request GET 'https://bandcamp.com/api/track/3/info?key=perladruslasaemingserligr&track_id=413445635'

1;