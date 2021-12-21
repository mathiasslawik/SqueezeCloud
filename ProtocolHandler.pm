package Plugins::SqueezeCloud::ProtocolHandler;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by David Blackman (first release), Robert Gibbon (improvements),
#   Daniel Vijge (improvements)
# See file LICENSE for full license details

use strict;

use base qw(Slim::Player::Protocols::HTTPS);

use List::Util qw(min max);
use LWP::Simple;
use LWP::UserAgent;
use HTML::Parser;
use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use XML::Simple;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Scalar::Util qw(blessed);

# Use data dumper for debug logging
use Data::Dumper;
local $Data::Dumper::Terse = 1;

my $log   = logger('plugin.squeezecloud');

my %fetching; # hash of ids we are fetching metadata for to avoid multiple fetches

Slim::Player::ProtocolHandlers->registerHandler('soundcloud', __PACKAGE__);

use strict;
use base 'Slim::Player::Protocols::HTTP';

use IO::Socket::SSL;
IO::Socket::SSL::set_defaults(
		SSL_verify_mode => Net::SSLeay::VERIFY_NONE() 
			) if preferences('server')->get('insecureHTTPS');

my $prefs = preferences('plugin.squeezecloud');

$prefs->init({ apiKey => "", playmethod => "stream" });

# TODO: Fix seeking by refreshing the Soundcloud CDN MP3 URL as this URL contains an access policy that expires after some time, thus preventing seeking
sub canSeek { 0 }

sub getAuthenticationHeaders() {
	return 'Authorization' => 'OAuth ' . $prefs->get('apiKey');
}

sub _convertJSONToSlimMetadata {
	my ($json) = shift;

	my $betterArtwork = getBetterArtworkURL($json->{'artwork_url'} || "");

	return {
		duration => int($json->{'duration'} / 1000),
		name => $json->{'title'},
		title => $json->{'title'},
		artist => $json->{'user'}->{'username'},
		album => " ",
		#type => 'soundcloud',
		#play => getStreamURL($json),
		#url  => $json->{'permalink_url'},
		#link => "soundcloud://" . $json->{'id'},
		bitrate   => '320kbps',
		type      => 'MP3 (SoundCloud)',
		#info_link => $json->{'permalink_url'},
		icon => $betterArtwork,
		image => $betterArtwork,
		cover => $betterArtwork
	};
}

sub extractDownloadOrStreamUrlFromJsonTrackInfo {
	my $jsonTrackInfo = shift;

	if ($prefs->get('playmethod') eq 'download' && exists($jsonTrackInfo->{'download_url'}) && defined($jsonTrackInfo->{'download_url'}) && $jsonTrackInfo->{'downloadable'} eq '1') {
		return $jsonTrackInfo->{'download_url'};
	}
	else {
		return $jsonTrackInfo->{'stream_url'};
	}
}

sub getBetterArtworkURL {
	my $artworkURL = shift;
	$artworkURL =~ s/-large/-t500x500/g;
	return $artworkURL;
}

sub getFormatForURL () { 'mp3' }

sub isRemote { 1 }

# TODO: Check if we could simplify gotNextTrack by using scanURL (see for example scanUrl in Podcasts protocol handler)
sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

# Next track handler.
# To get the "real" streaming URL from the Soundcloud CDN, we need to make an authenticated request to the
# stream/download URL contained in the track JSON and use the URL in the HTTP Location header for playing.
sub gotNextTrack {
	my $http   = shift;

	my $client = $http->params->{client};
	my $song   = $http->params->{song};
	my $successCb = $http->params->{successCb};
	my $errorCb = $http->params->{errorCb};

	my $jsonTrackInfo  = eval { from_json( $http->content ) };

	if ( $@ || $jsonTrackInfo->{error} ) {
		# We didn't get the next track to play
		if ( $log->is_warn ) {
			$log->warn( 'Soundcloud error getting next track: ' . ( $@ || $jsonTrackInfo->{error} ) );
		}

		if ( $client->playingSong() ) {
			$client->playingSong()->pluginData( {
				songName => $@ || $jsonTrackInfo->{error},
			} );
		}
	
		$errorCb->( 'PLUGIN_SQUEEZECLOUD_NO_INFO', $jsonTrackInfo->{error} );
		return;
	}
	
	# Save JSON track info for this track
	$song->pluginData( $jsonTrackInfo );

	my $soundcloudStreamURL = extractDownloadOrStreamUrlFromJsonTrackInfo($jsonTrackInfo);

	# TODO: Check the dedicated API for retrieving the stream URLs (https://api.soundcloud.com/tracks/{track_id}/streams)
	# Although, it does not support downloads, even with the current way of handling downloads, the API does not
	# guarantee that the download file format is playable or streaming-friendly.
	my $userAgent = LWP::UserAgent->new(
		requests_redirectable => [],
	);

	my $streamUrlHttpResponse = $userAgent->get($soundcloudStreamURL, getAuthenticationHeaders() );
	my $locationHeader = $streamUrlHttpResponse->header( 'location' );

	if (!$locationHeader) {
		$log->error('Error: Failed to get redirect location header from ' . $soundcloudStreamURL);
		$log->debug($streamUrlHttpResponse->status_line);
		$http->params->{'errorCallback'}->( 'PLUGIN_SQUEEZECLOUD_STREAM_FAILED', $jsonTrackInfo->{error} );
		return;
	}

	$log->debug('Setting Stream URL to Soundcloud CDN URL ' . $locationHeader);
	$song->streamUrl($locationHeader);

	my $slimMetaInformation = _convertJSONToSlimMetadata($jsonTrackInfo);

	$song->duration( $slimMetaInformation->{duration} );

	my $cache = Slim::Utils::Cache->new;
	$log->info("setting ". 'soundcloud_meta_' . $jsonTrackInfo->{id});
	$cache->set( 'soundcloud_meta_' . $jsonTrackInfo->{id}, $slimMetaInformation, 86400 );

	$successCb->();
}

sub gotNextTrackError {
	my $http = shift;

	$http->params->{errorCallback}->( 'PLUGIN_SQUEEZECLOUD_ERROR', $http->error );
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
		
	my $client = $song->master();
	my $url    = $song->currentTrack()->url;
		
	# Get next track
	my ($id) = $url =~ m{^soundcloud://(.*)$};
		
	# Talk to SN and get the next track to play
	my $trackURL = "https://api.soundcloud.com/tracks/" . $id;
		
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotNextTrack,
		\&gotNextTrackError,
		{
			client        => $client,
			song          => $song,
			successCb	  => $successCb,
			errorCb       => $errorCb,
			timeout       => 35,
		},
	);
		
	main::DEBUGLOG && $log->is_debug && $log->debug("Getting track from soundcloud for $id");
		
	$http->get( $trackURL, getAuthenticationHeaders() );
}

# To support remote streaming (synced players, slimp3/SB1), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;
	my $track     = $song->pluginData();

	$log->info( 'Remote streaming Soundcloud track: ' . $streamUrl );

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $song,
		client  => $client,
	} ) || return;

	${*$sock}{contentType} = 'audio/mpeg';

	return $sock;
}


# Track Info menu
sub trackInfo {
	my ( $class, $client, $track ) = @_;

	my $url = $track->url;
	$log->info("trackInfo: " . $url);
}

# Track Info menu
sub trackInfoURL {
	my ( $class, $client, $url ) = @_;
	$log->info("trackInfoURL: " . $url);
}

# Returns metadata for a soundcloud URL. This method is called quite often to poll data by clients, therefore we use
# caching to speed things up. Additionally, we check all playlist items if their metadata has already been fetched
# and fetch it if not.
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	#log->debug("getMetadataFor $url");

	return {} unless $url;

	my $icon = $class->getIcon();
	my $cache = Slim::Utils::Cache->new;

	# If metadata is not here, fetch it so the next poll will include the data
	my ($trackId) = $url =~ m{soundcloud://(.+)};

	my $meta      = $cache->get( 'soundcloud_meta_' . $trackId );
	if ( !defined $meta) {
		# Go fetch metadata for all tracks on the playlist without metadata
		for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
			my $trackURL = blessed($track) ? $track->url : $track;

			if ( $trackURL =~ m{soundcloud://(.+)} ) {
				my $id = $1;

				if ( !$cache->get("soundcloud_meta_$id") ) {
					if ( main::DEBUGLOG && $log->is_debug ) {
						$log->debug( "Need to fetch metadata for: $id");
					}

					if(!$client->master->pluginData( "fetchingMeta$id")) {
						$client->master->pluginData( "fetchingMeta$id" => 1);

						my $fetch = sub {
							Slim::Networking::SimpleAsyncHTTP->new(
								sub {
									my $http = shift;
									my $jsonTrackInfo = eval { from_json($http->content) };
									my $slimMetaInformation = _convertJSONToSlimMetadata($jsonTrackInfo);

									$log->info("setting ". 'soundcloud_meta_' . $jsonTrackInfo->{id});
									$cache->set( 'soundcloud_meta_' . $jsonTrackInfo->{id}, $slimMetaInformation, 86400 );

									$client->master->pluginData( "fetchingMeta$id" => 0);
								},
								sub {
									$log->warn("error: $_[1]");

									$client->master->pluginData( "fetchingMeta$id" => 0);
								},
							)->get("https://api.soundcloud.com/tracks/$id", getAuthenticationHeaders());
						};

						$fetch->();
					}
				}
			}
		}
	}

	return $meta || {
		bitrate   => '320kbps',
		type      => 'MP3 (SoundCloud)',
		icon      => $icon,
		cover     => $icon,
	};
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;

	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	return $class->SUPER::canDirectStream( $client, $song->streamUrl(), $class->getFormatForURL() );
}

# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;

	main::INFOLOG && $log->info("Direct stream failed: $url [$response] $status_line");

	$client->controller()->playerStreamingFailed( $client, 'PLUGIN_SQUEEZECLOUD_STREAM_FAILED' );
}

sub explodePlaylist {
	my ( $class, $client, $uri, $callback ) = @_;

	if ( $uri =~ Plugins::SqueezeCloud::Plugin::PAGE_URL_REGEXP ) {
		Plugins::SqueezeCloud::Plugin::urlHandler(
			$client,
			sub { $callback->([map {$_->{'play'}} @{$_[0]->{'items'}}]) },
			{'search' => $uri},
		);
	}
	else {
		$callback->([$uri]);
	}
}

1;
