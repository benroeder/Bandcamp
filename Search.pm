package Plugins::Bandcamp::Search;

use strict;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Bandcamp::Plugin;
use Plugins::Bandcamp::API;
use Plugins::Bandcamp::Scraper;

use constant MAX_RECENT_ITEMS => 50;
use constant RECENT_CACHE_TTL => 60*60*24*365;

my $log = logger('plugin.bandcamp');

my $search_results = {};

my $cache;

sub init {
	$cache = shift;
}

sub search {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{q};

	$search_results->{$client || ''} = {};

	_search_artists($client, $cb, $params);
	_search_tags($client, $cb, $params);
}

sub search_artists {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{q};

	$search_results->{$client || ''} = {
		tag_search => [],
	};

	_search_artists($client, $cb, $params);	
}

sub search_tags {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{q};

	$search_results->{$client || ''} = {
		artist_search => [],
	};

	_search_tags($client, $cb, $params);
}

sub _search_tags {
	my ($client, $cb, $params) = @_;
	
	Plugins::Bandcamp::Scraper::search_tags($client,
		sub {
			my ($items) = @_;

			my $search = $params->{search};
			add_recent_search($search) if $search && scalar @{ $items->{discography} };
			
			$search_results->{$client || ''}->{'tag_search'} = Plugins::Bandcamp::Plugin::album_list(\&Plugins::Bandcamp::API::get_item_info_by_url, $items);
			_search_done($client, $cb);
		}, 
		$params,
	);
}

sub _search_artists {
	my ($client, $cb, $params) = @_;
	
	Plugins::Bandcamp::API::search_artists($client,
		sub {
			my ($items) = @_;
			
			my $search = $params->{search};
			add_recent_search($search) if ($search && scalar @{ $items->{results} });
			
			$search_results->{$client || ''}->{'artist_search'} = Plugins::Bandcamp::Plugin::artist_list($items);
			_search_done($client, $cb);
		}, 
		$params, 
	);
}

sub _search_done {
	my ($client, $cb) = @_;
	
	return unless $search_results->{$client || ''}->{'tag_search'} && $search_results->{$client || ''}->{'artist_search'};

	my $hasTags = scalar @{ $search_results->{$client || ''}->{'tag_search'} };

	my $items = [
		map {
			if ($hasTags) {
				$_->{name}  .= ' (' . cstring($client, 'ARTIST') . ')';
				$_->{line1} .= ' (' . cstring($client, 'ARTIST') . ')' if $_->{line1};
				$_->{image} ||= 'html/images/artists.png';
			}
			$_;
		} @{ $search_results->{$client || ''}->{'artist_search'} }
	];
	
	push @$items, sort { 
		uc($a->{name}) cmp uc($b->{name}) 
	} @{$search_results->{$client || ''}->{'tag_search'}};
	
	if (!scalar @$items) {
		$items = [{
			name => cstring($client, 'EMPTY'),
			type => 'text',
		}];
	}
	
	$cb->( { 
		items => $items
	} );
}

sub add_recent_search {
	_recent_search(shift, 1);
}

sub remove_recent_search {
	_recent_search(shift);
}

sub get_recent_searches {
	return _recent_search();
}

sub _recent_search {
	my ($search, $add) = @_;
	
	my $recent = $cache->get('recent_searches') || [];
	$recent = [] if ref $recent ne 'ARRAY' || ref $recent->[0] ne 'HASH';

	if (defined $search) {
		my $existing;
		my $oldest;
		my $oldest_ts = time();
		my $x = 0;
		
		foreach (@$recent) {
			if ( lc($_->{name}) eq lc($search) ) {
				$existing = $x; 
			}
			
			if ( ($_->{ts} || -1) < $oldest_ts) {
				$oldest = $x;
				$oldest_ts = $_->{ts};
			}
			
			$x++;
		}

		# update timestamp if it already exists
		if ($add && defined $existing) {
			$recent->[$existing]->{ts} = time();
		}
		# add search term if not defined yet
		elsif ($add) {
			push @$recent, {
				name => $search,
				ts   => time(),
			};
		}
		# remove item
		elsif ($existing) {
			splice(@$recent, $existing, 1);
		}

		# remove oldest item if the list is larger than desired
		if (scalar @$recent > MAX_RECENT_ITEMS && defined $oldest) {
			splice(@$recent, $oldest, 1);
		}
		
		$cache->set('recent_searches', $recent, RECENT_CACHE_TTL);
	}
	
	return [ map { $_->{name} } @$recent ];
}

sub recent_searches {
	my ($client, $cb, $args) = @_;

	my $recent = _recent_search();
	
	my $items = [];
	
	foreach (@$recent) {
		push @$items, {
			type => 'link',
			name => $_,
			url  => \&search,
			passthrough => [{
				q => $_
			}],
		}
	}
	
	$cb->({
		items => $items
	});
}

1;