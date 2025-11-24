package Plugins::Bandcamp::HomeExtras;

use strict;

use Plugins::Bandcamp::Plugin;

Plugins::Bandcamp::HomeExtraDaily->initPlugin();
Plugins::Bandcamp::HomeExtraWeekly->initPlugin();
Plugins::Bandcamp::HomeExtraRecentlyPlayed->initPlugin();

1;

package Plugins::Bandcamp::HomeExtraBase;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	my $tag = $args{tag};

	$class->SUPER::initPlugin(
		feed => sub { handleFeed($tag, @_) },
		tag  => "Bandcamp${tag}",
		extra => {
			title => $args{title},
			icon  => $args{icon} || Plugins::Bandcamp::Plugin->_pluginDataFor('icon'),
			needsPlayer => 1,
		}
	);
}

sub handleFeed {
	my ($tag, $client, $cb, $args) = @_;

	$args->{params}->{menu} = "home_heroes_${tag}";

	Plugins::Bandcamp::Plugin::handleFeed($client, $cb, $args);
}


package Plugins::Bandcamp::HomeExtraDaily;

use base qw(Plugins::Bandcamp::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_BANDCAMP_DAILY',
		tag => 'daily'
	);
}

1;


package Plugins::Bandcamp::HomeExtraWeekly;

use base qw(Plugins::Bandcamp::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_BANDCAMP_WEEKLY',
		tag => 'weekly'
	);
}

1;


package Plugins::Bandcamp::HomeExtraRecentlyPlayed;

use base qw(Plugins::Bandcamp::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_BANDCAMP_RECENTLY_PLAYED',
		tag => 'recently_played'
	);
}

1;

