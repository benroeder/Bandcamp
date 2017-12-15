package Plugins::Bandcamp::Search;

use strict;
use Tie::Cache::LRU;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Bandcamp::Plugin;
use Plugins::Bandcamp::API;
use Plugins::Bandcamp::Scraper;

use constant MAX_RECENT_ITEMS => 50;
use constant RECENT_CACHE_TTL => 'never';

my $log = logger('plugin.bandcamp');

my $search_results = {};

my %recent_searches;
tie %recent_searches, 'Tie::Cache::LRU', MAX_RECENT_ITEMS;

my $cache;

sub init {
	$cache = shift;

	# initialize recent searches: need to add them to the LRU cache ordered by timestamp
	my $cached = $cache->get('recent_searches') || {};
	map {
		$recent_searches{$_} = $cached->{$_};
	} sort { 
		$cached->{$a}->{ts} <=> $cached->{$a}->{ts} 
	} keys %$cached;
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

sub search_url {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{q};

	# Because search replaces '.' by ' ':
	$params->{search} =~ s/ /./g;
	
	$search_results->{$client || ''} = {};

	_search_url($client, $cb, $params);
}

sub _search_url {
	my ($client, $cb, $params) = @_;

	Plugins::Bandcamp::Plugin::get_item_info_by_url(
		$client, $cb, $params, { url => $params->{search} }
	);
}

sub _search_tags {
	my ($client, $cb, $params) = @_;
	
	Plugins::Bandcamp::Scraper::search_tags($client,
		sub {
			my ($items) = @_;

			my $search = $params->{search};
			add_recent_search($search) if $search && scalar @{ $items->{discography} };
			
			$search_results->{$client || ''}->{'tag_search'} = Plugins::Bandcamp::Plugin::album_list($client, \&Plugins::Bandcamp::Plugin::get_item_info_by_url, $items);
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
	my $search = shift;
	
	return unless $search;
	
	$recent_searches{$search} = {
		ts => time(),
	};
	
	# don't cache %recent_searches directly, as it's a Tie::Cache::LRU object
	$cache->set('recent_searches', { map { 
		$_ => $recent_searches{$_} 
	} keys %recent_searches }, RECENT_CACHE_TTL);
}

sub recent_searches {
	my ($client, $cb, $args) = @_;

	my $recent = [ 
		sort { lc($a) cmp lc($b) } 
		grep { $recent_searches{$_} }
		keys %recent_searches 
	];
	
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

	$items = [ {
		name => string('EMPTY'),
		type => 'text',
	} ] if !scalar @$items;
	
	$cb->({
		items => $items
	});
}

1;