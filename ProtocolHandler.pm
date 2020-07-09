package Plugins::Bandcamp::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTP);

use Plugins::Bandcamp::Plugin;

sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;

	if ($url =~ m{https?://bandcamp\.com/stream_redirect}) {
		return $cb->([$url]);
	}

	Plugins::Bandcamp::Plugin::get_item_info_by_url( $client, sub {
		$cb->([ map { $_->{'play'} // () } @{$_[0]} ]);
	}, {}, { 'url' => $url } );
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	return Plugins::Bandcamp::Plugin::metadata_provider($client, $url);
}

1;