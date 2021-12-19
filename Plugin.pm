package Plugins::SqueezeCloud::Plugin;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by David Blackman (first release), 
#   Robert Gibbon (improvements),
#   Daniel Vijge (improvements),
#   Robert Siebert (improvements),
# See file LICENSE for full license details

use strict;
use utf8;

use vars qw(@ISA);

use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use LWP::Simple;
use LWP::UserAgent;
use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Time::Seconds;

# Use data dumper for debug logging
use Data::Dumper;
local $Data::Dumper::Terse = 1;

# Defines the timeout in seconds for a http request
use constant HTTP_TIMEOUT => 15;

# The maximum items that can be fetched via the API in one call
use constant API_MAX_ITEMS_PER_CALL => 200;

# The default number of items to fetch in one API call
use constant API_DEFAULT_ITEMS_COUNT => 30;

# The maximum value that can be fetched via the API. This means that no more 
# than 8000 + 200 items can exist in a menu list.
use constant API_MAX_ITEMS => 500;

# Which URLs should we catch when pasted into the "Tune In URL" field?
use constant PAGE_URL_REGEXP => qr{^https?://soundcloud\.com/};

use IO::Socket::SSL;
IO::Socket::SSL::set_defaults(
		SSL_verify_mode => Net::SSLeay::VERIFY_NONE()
			) if preferences('server')->get('insecureHTTPS');

my $log;
my $compat;

my %METADATA_CACHE= {};

# This is the entry point in the script
BEGIN {
	# Initialize the logging
	$log = Slim::Utils::Log->addLogCategory({
		'category'     => 'plugin.squeezecloud',
		'defaultLevel' => 'WARN',
		'description'  => string('PLUGIN_SQUEEZECLOUD'),
	});

	# Always use OneBrowser version of XMLBrowser by using server or packaged
	# version included with plugin
	if (exists &Slim::Control::XMLBrowser::findAction) {
		$log->info("using server XMLBrowser");
		require Slim::Plugin::OPMLBased;
		push @ISA, 'Slim::Plugin::OPMLBased';
	} else {
		$log->info("using packaged XMLBrowser: Slim76Compat");
		require Slim76Compat::Plugin::OPMLBased;
		push @ISA, 'Slim76Compat::Plugin::OPMLBased';
		$compat = 1;
	}
}

# Get the data related to this plugin and preset certain variables with 
# default values in case they are not set
my $prefs = preferences('plugin.squeezecloud');
$prefs->init({ apiKey => "", playmethod => "stream" });

# This is called when squeezebox server loads the plugin.
# It is used to initialize variables and the like.
sub initPlugin {
	my $class = shift;

	# Initialize the plugin with the given values. The 'feed' is the first
	# method called. The available menu entries will be shown in the new
	# menu entry 'soundcloud'.
	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'squeezecloud',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') ? 1 : undef,
		weight => 10,
	);

	if (!$::noweb) {
		require Plugins::SqueezeCloud::Settings;
		Plugins::SqueezeCloud::Settings->new;
	}

	Slim::Formats::RemoteMetadata->registerProvider(
		match => qr/soundcloud\.com/,
		func => \&metadata_provider,
	);

	Slim::Player::ProtocolHandlers->registerHandler(
		soundcloud => 'Plugins::SqueezeCloud::ProtocolHandler'
	);

	Slim::Player::ProtocolHandlers->registerURLHandler(
		PAGE_URL_REGEXP() => 'Plugins::SqueezeCloud::ProtocolHandler'
	) if Slim::Player::ProtocolHandlers->can('registerURLHandler');
}

# Called when the plugin is stopped
sub shutdownPlugin {
	my $class = shift;
}

# Returns the name to display on the squeezebox
sub getDisplayName { 'PLUGIN_SQUEEZECLOUD' }

# Returns the default metadata for the track which is specified by the URL.
# In this case only the track title that will be returned.
sub defaultMeta {
	my ( $client, $url ) = @_;

	return {
		title => Slim::Music::Info::getCurrentTitle($url)
	};
}

sub getAuthenticationHeaders() {
	return 'Authorization' => 'OAuth ' . $prefs->get('apiKey');
}

# Extracts the available metadata for a tracks from the JSON data. The data 
# is cached and then returned to be presented to the user. 
sub _makeMetadata {
	my ($json) = shift;

	# Get the icon from the artwork_url.
	# Get the 500x500 high quality version, as specified in SoundCloud API.
	my $icon = "";
	if (defined $json->{'artwork_url'}) {
		$icon = $json->{'artwork_url'};
		$icon =~ s/-large/-t500x500/g;
	}

	my $DATA = {
		duration => $json->{'duration'} / 1000,
		name => $json->{'title'},
		title => $json->{'title'},
		artist => $json->{'user'}->{'username'},
		album => " ",
		play => "soundcloud://" . $json->{'id'},
		#url  => $json->{'permalink_url'},
		#link => "soundcloud://" . $json->{'id'},
		bitrate => '320kbps',
		type => 'MP3 (SoundCloud)',
		icon => $icon,
		image => $icon,
		cover => $icon,
		on_select => 'play',
	};

	my %DATA1 = %$DATA;
	my %DATA2 = %$DATA;
	my %DATA3 = %$DATA;

	$METADATA_CACHE{$DATA->{'play'}} = \%DATA1;
	$METADATA_CACHE{$DATA->{'link'}} = \%DATA2;

	return \%DATA3;
}

# This method is called when the Slim::Networking::SimpleAsyncHTTP encountered 
# an error or no http repsonse was received. 
sub _gotMetadataError {
	my $http   = shift;
	my $client = $http->params('client');
	my $url    = $http->params('url');
	my $error  = $http->error;

	$log->is_debug && $log->debug( "Error fetching Web API metadata: $error" );

	$client->master->pluginData( webapifetchingMeta => 0 );

	# To avoid flooding the SOUNDCLOUD servers in the case of errors, we just ignore further
	# metadata for this track if we get an error
	my $meta = defaultMeta( $client, $url );
	$meta->{_url} = $url;

	$client->master->pluginData( webapimetadata => $meta );
}

# This method is called when the Slim::Networking::SimpleAsyncHTTP 
# method has received a http response.
sub _gotMetadata {
	my $http      = shift;
	my $client    = $http->params('client');
	my $url       = $http->params('url');
	my $content   = $http->content;

	# Check if there is an error message from the last eval() operator
	if ( $@ ) {
		$http->error( $@ );
		_gotMetadataError( $http );
		return;
	}

	$client->master->pluginData( webapifetchingMeta => 0 );

	my $json = eval { from_json($content) };
	my $user_name = $json->{'user'}->{'username'};

	my $DATA = _makeMetadata($json);

	my $ua = LWP::UserAgent->new(
		requests_redirectable => [],
	);

	my $res = $ua->get( getStreamURL($json), getAuthenticationHeaders() );

	my $stream = $res->header( 'location' );

	if ($stream =~ /ak-media.soundcloud.com\/(.*\.mp3)/) {
		my %DATA1 = %$DATA;
		my %DATA2 = %$DATA;
		my %DATA3 = %$DATA;
		$METADATA_CACHE{$1} = \%DATA1;
		$METADATA_CACHE{getStreamURL($json)} = \%DATA2;
		$METADATA_CACHE{getStreamURL($json)} = \%DATA3;
	}

	return;
}

# Returns either the stream URL or the download URL from the given JSON data. 
sub getStreamURL {
	my $json = shift;

	if ($prefs->get('playmethod') eq 'download' && exists($json->{'download_url'}) && defined($json->{'download_url'}) && $json->{'downloadable'} eq '1') {
		return $json->{'download_url'};
	}
	else {
		return $json->{'stream_url'};
	}
}

sub fetchMetadata {
	my ( $client, $url ) = @_;

	if ($url =~ /tracks\/\d+\/stream/) {

		my $queryUrl = $url;
		$queryUrl =~ s/\/stream/.json/;

		# Call the server to fetch the data via the asynchronous http request.
		# The methods are called when a response was received or an error
		# occurred. Additional information to the http call is passed via
		# the hash (third parameter).
		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			\&_gotMetadata,
			\&_gotMetadataError,
			{
				client     => $client,
				url        => $url,
				timeout    => HTTP_TIMEOUT,
			},
		);

		$http->get($queryUrl, getAuthenticationHeaders());
	}
}

sub _parseTracks {
	my ($json, $menu) = @_;

	for my $entry (@$json) {
		#		if ($entry->{'streamable'}) {
		push @$menu, _makeMetadata($entry);
		#		}
	}
}

sub friendsHandler {
	my (undef, $callback, undef, $passthrough) = @_;

	my $friendsUri = $passthrough->{'uri'} || 'https://api.soundcloud.com/me/followings';

	$log->debug("fetching: $friendsUri");

	my $httpRequest = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;

			my $friendsJson = eval { from_json($http->content) };

			$callback->(createFriendsEntries($friendsJson))
		},
		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$callback->([ { name => $_[1], type => 'text' } ]);
		},
	);

	return $httpRequest->get($friendsUri, getAuthenticationHeaders());
}

# Main method that is called when the user selects a menu item. It is 
# specified in the menu array by the key 'url'. The passthrough array 
# contains the additional values that is passed to this method to 
# differentiate what shall be done in here.
sub tracksHandler {
	my ($client, $callback, $args, $passDict) = @_;

	# Get the index (offset) where to start fetching items
	my $index    = ($args->{'index'} || 0); # ie, offset

	# The maximum amount of items to fetch
	my $quantity = $args->{'quantity'} || API_MAX_ITEMS_PER_CALL;

	my $searchType = $passDict->{'type'};
	my $searchStr = ($searchType eq 'tags') ? "tags=" : "q=";
	my $search   = $args->{'search'} ? $searchStr . URI::Escape::uri_escape_utf8($args->{'search'}) : '';

	# The parser is the method that will be called when the
	# server has returned some data in the SimpleAsyncHTTP call.
	my $parser = $passDict->{'parser'} || \&_parseTracks;

	my $params = $passDict->{'params'} || '';

	$log->debug('search type: ' . $searchType);
	$log->debug("index: " . $index);
	$log->debug("quantity: " . $quantity);

	# The new menu that will be shows when the server request has been
	# processed (the user has clicked something from the previous menu).
	my $menu = [];

	# fetch in stages as api only allows 50 items per response, cli clients require $quantity responses which can be more than 50
	my $fetch;

	# FIXME: this could be sped up by performing parallel requests once the number of responses is known??

	$fetch = sub {
		# in case we've already fetched some of this page, keep going
		my $i = $index + scalar @$menu;
		$log->debug("i: " . $i);

		# Limit the amount of items to fetch because the API allows only a max
        # of 200 per response. See https://developers.soundcloud.com/docs#pagination
		my $max = min($quantity - scalar @$menu, API_MAX_ITEMS_PER_CALL);
		$log->debug("max: " . $max);
        $quantity = $max;

		my $method = "https";
		my $uid = $passDict->{'uid'} || '';

        # If this is set to one then the user has provided the API key. This 
        # is the case when the menu item in the toplevel method are active.
		my $authenticated = 0;
		my $extras = '';

		my $resource = "tracks";

        # Check the given type (defined by the passthrough array). Depending 
        # on the type certain URL parameters will be set. 
		if ($searchType eq 'playlists') {
			# Previous error: $passDics->{'pid'} is always the same as the first entry
			my $id = $passDict->{'pid'} || '';
			$authenticated = 1;

			$resource = "playlists/$id";
            if ($id eq '') {
                if ($uid ne '') {
                    $resource = "users/$uid/playlists";
                    $quantity = API_DEFAULT_ITEMS_COUNT;
                }
                elsif ($search ne '') {
                    $resource = "playlists";
                    $quantity = API_DEFAULT_ITEMS_COUNT;
                }
                else {
					$resource = "me/playlists";
                    $quantity = API_DEFAULT_ITEMS_COUNT;
                }
			}
			$extras = "offset=$i&limit=$quantity";

		} elsif ($searchType eq 'tracks') {
			$authenticated = 1;
			$resource = "users/$uid/tracks";
			$extras = "offset=$i&limit=$quantity";

		} elsif ($searchType eq 'favorites') {
			$authenticated = 1;
			$resource = "users/$uid/likes/tracks";
			if ($uid eq '') {
				$resource = "me/likes/tracks";
			}
			$extras = "offset=$i&limit=$quantity";

		} elsif ($searchType eq 'friends') {
			$authenticated = 1;
			$resource = "me/followings";
			$extras = "offset=$i"; #&limit=$quantity&";

		} elsif ($searchType eq 'friend') {
			$authenticated = 1;
			$resource = "users/$uid";
			$extras = "offset=$i&limit=$quantity";

		} elsif ($searchType eq 'activities') {
			$authenticated = 1;
			$resource = "me/activities";

			# The activities call does not honor the offset, only the limit
			# parameter, which is specified by the quantity variable. Add the
			# limit only when it is not 1 to get all activities. This shall
			# only be done when the user has selected the dashboard menu item.
			# When an item from the result list is selected, omit the limit
			# parameter.
            if ($quantity > 1) {
                $extras = "limit=$quantity&";
            }

		} else {
			$params .= "&filter=streamable";
		}

        my $queryUrl = $method."://api.soundcloud.com/".$resource."?" . $extras . $params . "&" . $search;

		$log->debug("fetching: $queryUrl");

		Slim::Networking::SimpleAsyncHTTP->new(
			# Called when a response has been received for the request.
			sub {
				my $http = shift;
				my $json = eval { from_json($http->content) };

                # Special logic for retrieving one friend, because the limit
                # and offset parameters are no longer supported by the API
                if ($searchType eq 'friends' && $quantity == 1) {
                    my $collection = $json->{'collection'};
                    my $i = 0;
                    for my $entry (@$collection) {
                        if ($i == $index) {
                            $json = { collection => [$entry]};
                        }
                        $i++;
                    }
                }

                # The activities call does not honor the offset, only the limit parameter. 
                # If the limit is one the first entry of the activities will be returned, 
                # regardless of the offset. This prevents getting the correct list item.
                # So get always all activities and parse only the item from the collection 
                # that matches the selected list item.  
                if ($searchType eq 'activities' && $quantity == 1) {
                    my $collection = $json->{'collection'};
                    my $i = 0;
                    for my $entry (@$collection) {
                        if ($i == $index) {
                            # Parse the single item
                            _parseActivity($entry, $menu);
                        }
                        $i++;
                    }
                } else {
                    # Use the specified parser method for all other calls.
                    $parser->($json, $menu);
                }

				# max offset = 8000, max index = 200 sez soundcloud https://developers.soundcloud.com/docs#pagination
				my $total = API_MAX_ITEMS + $quantity;
				if (exists $passDict->{'total'}) {
					$total = $passDict->{'total'}
				}

                if ($searchType eq 'activities' && $quantity > 1) {
                    $total = $quantity;
                }

				$log->info("this page: " . scalar @$menu . " total: $total");

				# TODO: check this logic makes sense
				if (scalar @$menu < $quantity) {
					$total = $index + @$menu;
					$log->debug("short page, truncate total to $total");
				}

				# awful hack
				if ($searchType eq 'friend' && (defined $args->{'index'})) {
					$callback->({
                        items  => $menu,
                        offset => 0,
                        total  => $total,
                    });
				} else {
					$callback->({
						items  => $menu,
						offset => $index,
						total  => $total,
					});
				}
			},
			# Called when no response was received or an error occurred.
			sub {
				$log->warn("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},

		)->get($queryUrl, getAuthenticationHeaders());
	};

	$fetch->();
}

# TODO: make this async
sub metadata_provider {
	my ( $client, $url ) = @_;

    # Check if metadata has been already cached for the given item
	if (exists $METADATA_CACHE{$url}) {
		return $METADATA_CACHE{$url};
	}

    # Check if the url matches the pattern, if yes check if metadata
    # has been cached for the scalar in the one parenthesis set.
	if ($url =~ /ak-media.soundcloud.com\/(.*\.mp3)/) {
		return $METADATA_CACHE{$1};
	}

	if ( !$client->master->pluginData('webapifetchingMeta') ) {
        # The fetchMetadata method will invoke an asynchronous http request. This will 
        # start a timer that is linked with the method fetchMetadata. Kill any pending 
        # or running request that is already active for the fetchMetadata method. 
		Slim::Utils::Timers::killTimers( $client, \&fetchMetadata );

		# Start fetching new metadata in the background
        $client->master->pluginData( webapifetchingMeta => 1 );
		fetchMetadata( $client, $url );
	}

	return { };
}

# Handler for Playlists URIs, i.e., URIs referencing a list of playlists.
#
# This handler calls itself recursively to retrieve the list of playlists linked through next_href
#
# For the retrieved JSON structure, see:
# https://developers.soundcloud.com/docs/api/explorer/open-api#/users/get_users__user_id__playlists
sub listOfPlaylistsUriHandler {
	my (undef, $callback, undef, $passthrough) = @_;

	my $uri = $passthrough->{'playlistsUri'};

	my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;

				my $playlistJSON = eval { from_json($http->content) };

				my $items = [];

				push @$items, @{_convertListOfSoundcloudPlaylistsToSlimserverPlalistsList($playlistJSON->{'collection'})};

				if(defined $playlistJSON->{'next_href'}) {
					my $nextItemsReceiver = sub {
						my ($callbackResult) = @_;

						push @$items, @{$callbackResult->{ 'items' }};

						$callback->({
							items => $items
						})
					};

					# Recursion call to fetch the next playlists
					listOfPlaylistsUriHandler(undef, \&{$nextItemsReceiver}, undef, { playlistsUri => $playlistJSON->{'next_href'} })
				} else {
					$callback->({
						items => $items
					});
				}
			},
			sub {
				$log->warn("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
			{
				cache => 1
			}
		)->get($uri, getAuthenticationHeaders());
	};

	$fetch->();
}

# Handler for Playlist URIs
sub playlistUriHandler {
	my (undef, $callback, undef, $passthrough) = @_;

	my $uri = $passthrough->{'playlistUri'};

	my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;

				#JSON Structure: https://developers.soundcloud.com/docs/api/explorer/open-api#/playlists/get_playlists__playlist_id_
				my $playlistJSON = eval { from_json($http->content) };

				my $menu = [];

				_parseTracks($playlistJSON->{'tracks'}, $menu);

				$callback->({ items => $menu });
			},
			sub {
				$log->warn("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			}
		)->get($uri, getAuthenticationHeaders());
	};

	$fetch->();
}
# This method is called when the user has selected the last main menu where
# an URL can be entered manually. It will assemble the given URL and fetch 
# the data from the server.
sub urlHandler {
	my ($client, $callback, $args) = @_;

	my $url = $args->{'search'};
	# awful hacks, why are periods being replaced?
	$url =~ s/ com/.com/;
	$url =~ s/www /www./;

	$url = URI::Escape::uri_escape_utf8($url);
	my $queryUrl = "https://api.soundcloud.com/resolve?url=$url";
    $log->debug("fetching: $queryUrl");

	my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $json = eval { from_json($http->content) };

				if (exists $json->{'tracks'}) {
					$callback->({ items => [ _convertSoundcloudPlaylistEntryToSlimPlaylistEntry($json) ] });
				} else {
					$callback->({
						items => [ _makeMetadata($json) ]
					});
				}
			},
			sub {
				$log->warn("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
		)->get($queryUrl, getAuthenticationHeaders());
	};

	$fetch->();
}

# Get the tracks data from the JSON array and passes it to the parseTracks 
# method which will then add a menu item for each track
sub _parsePlaylistTracks {
	my ($json, $menu) = @_;
	_parseTracks($json->{'tracks'}, $menu);
}

# Converts a Soundcloud Playlist JSON Entry to a Slimserver playlist Entry
sub _convertSoundcloudPlaylistEntryToSlimPlaylistEntry {
	# $entry Schema: https://developers.soundcloud.com/docs/api/explorer/open-api#/playlists/get_playlists__playlist_id_
	my ($JSON) = @_;

	my $additionalInfo = "";
	my $slimMenuEntry = {
		type		=> 'playlist',
		url         => \&playlistUriHandler,
		passthrough => [
			{
				playlistUri => $JSON->{'uri'} . '?access=playable'
			}
		]
	};

	# IMAGE - use either the playlist artwork or the first artwork found in the tracks or the users artwork
	my $IMAGE = "";
	if (defined $JSON->{'artwork_url'}) {
		# Replace "large" with original size
		# For different sizes, see: https://stackoverflow.com/a/16549098
		$IMAGE = $JSON->{'artwork_url'} =~ s/-large/-original/gr;
	} elsif (defined $JSON->{'tracks'}) {
		while( my( $index, $track ) = each( @{$JSON->{'tracks'}} ) )
		{
			if( defined $track->{'artwork_url'} )
			{
				$IMAGE = $track->{'artwork_url'} =~ s/-large/-t500x500/gr;
				last;
			}
		}
	} elsif ($IMAGE eq "" && defined $JSON->{'user'}->{'avatar_url'}) {
		$IMAGE = $JSON->{'user'}->{'avatar_url'} =~ s/-large/-t500x500/gr;
	}
	$slimMenuEntry->{'image'} = $IMAGE;

	# TRACK COUNT
	my $numTracks = 0;
	if (exists $JSON->{'tracks'} || exists $JSON->{'track_count'}) {
		$numTracks = exists $JSON->{'tracks'} ? scalar(@{$JSON->{'tracks'}}) : scalar($JSON->{'track_count'});
		$additionalInfo .= "$numTracks " . lc(string('PLUGIN_SQUEEZECLOUD_TRACKS'));
	}

    # PLAY TIME
	my $totalSeconds = ($JSON->{'duration'} || 0) / 1000;
	if ($totalSeconds != 0) {
		my $minutes = int($totalSeconds / 60);
		my $seconds = $totalSeconds % 60;
        if ($numTracks > 0) {
            $additionalInfo .= ", ";
        }
		$additionalInfo .= "${minutes}m${seconds}s";
	}

    # TITLE
    my $title = $JSON->{'title'};
	$title .= " ($additionalInfo)";
	$slimMenuEntry->{'name'} = $title;

	return $slimMenuEntry;
}

# Converts a list of Soundcloud JSON playlists to a Slimserver playlist of playlists
sub _convertListOfSoundcloudPlaylistsToSlimserverPlalistsList {
	# Should be a JSON array
	my ($json) = @_;

	my $menu = [];

	for my $entry (@$json) {
		push @$menu, _convertSoundcloudPlaylistEntryToSlimPlaylistEntry($entry);
	}

	return $menu;
}

# Goes through the list of available friends from the JSON data and parses the
# information for each friend (which is defined in the parseFriend method). 
# Each friend is added as a separate menu entry.
sub createFriendsEntries {
	my ($json) = @_;

	my $menu = [];

	for my $entry (@{$json->{'collection'}}) {
		my $image = $entry->{'avatar_url'};
		my $name = $entry->{'full_name'} || $entry->{'username'};
		my $favorite_count = $entry->{'public_favorites_count'};
		my $track_count = $entry->{'track_count'};
		my $playlist_count = $entry->{'playlist_count'};

		my $friendEntries = [];

		if ($favorite_count > 0) {
			push @$friendEntries, {
				name => string('PLUGIN_SQUEEZECLOUD_FAVORITES')
			};
		}

		if ($track_count > 0) {
			push @$friendEntries, {
				name => string('PLUGIN_SQUEEZECLOUD_TRACKS'),
			};
		}

		if ($playlist_count > 0) {
			push @$friendEntries, {
				name        => string('PLUGIN_SQUEEZECLOUD_PLAYLISTS') . " ($playlist_count)",
				url         => \&listOfPlaylistsUriHandler,
				passthrough => [ { playlistsUri => $entry->{'uri'} . '/playlists?access=playable&linked_partitioning=true' } ]
			};
		}

		my $friendEntry = {
			name  => $name,
			icon  => $image,
			image => $image,
			type  => "playlist",
			items => $friendEntries
		};

		push @$menu, $friendEntry
	}

	return($menu);
}

# Parses the given data. If the data is a playlist the number of tracks and 
# some additional data will be retrieved. The playlist or if the data is a 
# track will then be shown as a menu item. 
sub _parseActivity {
    my ($entry, $menu) = @_;

    my $created_at = $entry->{'created_at'};
    my $origin = $entry->{'origin'};
    my $tags = $entry->{'tags'};
    my $type = $entry->{'type'};

    if ($type =~ /playlist.*/) {
        my $playlistItem = _convertSoundcloudPlaylistEntryToSlimPlaylistEntry($origin);
        my $user = $origin->{'user'};
        my $user_name = $user->{'full_name'} || $user->{'username'};

        $playlistItem->{'name'} = $playlistItem->{'name'} . " - " . sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_SHARED_BY') . " %s", $user_name);
        push @$menu, $playlistItem;
    } else {
        my $track = $origin->{'track'} || $origin;
        my $user = $origin->{'user'} || $track->{'user'};
        my $user_name = $user->{'full_name'} || $user->{'username'};
        $track->{'artist_sqz'} = $user_name;

        my $subtitle = "";
        if ($type eq "favoriting") {
            $subtitle = sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_FAVORITED_BY') . " %s", $user_name);
        } elsif ($type eq "comment") {
            $subtitle = sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_COMMETED_BY') . " %s", $user_name);
        } elsif ($type =~ /track/) {
            $subtitle = sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_NEW_TRACK') . " %s", $user_name);
        } else {
            $subtitle = sprintf(string('PLUGIN_SQUEEZECLOUD_STREAM_SHARED_BY') . " %s", $user_name);
        }

        my $trackentry = _makeMetadata($track);
        $trackentry->{'name'} = $track->{'title'} . " - " . $subtitle;

        push @$menu, $trackentry;
    }
}

# Parses all available items in the collection. 
# Each item can either be a playlist or a track.
sub _parseActivities {
	my ($json, $menu) = @_;
	my $collection = $json->{'collection'};

	for my $entry (@$collection) {
		_parseActivity($entry, $menu);
	}
}

sub playerMenu { shift->can('nonSNApps') ? undef : 'RADIO' }

# First method that is called after the plugin has been initialized. 
# Creates the top level menu items that the plugin provides.
sub toplevel {
	my ($client, $callback, $args) = @_;

    # These are the available main menus. The variable type defines the menu
    # type (search allows text input, link opens another menu), the url defines
    # the method that shall be called when the user has selected the menu entry.
    # The array passthrough holds additional parameters that is passed to the
    # method defined by the url variable.
	my $callbacks = [];

    # Add the following menu items only when the user has specified an API key
	if ($prefs->get('apiKey') ne '') {

		# Menu entry to show all activities (Stream)
		push(@$callbacks,
			{ name => string('PLUGIN_SQUEEZECLOUD_ACTIVITIES'), type => 'link',
				url  => \&tracksHandler, passthrough => [ { type => 'activities', parser => \&_parseActivities} ] }
		);

		# Menu entry to show the 'friends' the user is following
		push(@$callbacks,
			{
				name        => string('PLUGIN_SQUEEZECLOUD_FRIENDS'),
				url         => \&friendsHandler
			}
		);

		# Menu entry to show the 'playlists' the user is following
        push(@$callbacks,
            { name => string('PLUGIN_SQUEEZECLOUD_PLAYLISTS'), type => 'link',
                url  => \&tracksHandler, passthrough => [ { type => 'playlists', parser => \&_convertListOfSoundcloudPlaylistsToSlimserverPlalistsList} ] },
        );

        # Menu entry to show the users favorites
		push(@$callbacks,
			{ name => string('PLUGIN_SQUEEZECLOUD_FAVORITES'), type => 'link',
				url  => \&tracksHandler, passthrough => [ { type => 'favorites' } ] }
		);

		# Menu entry 'New tracks'
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_NEW'), type => 'link',
			url  => \&tracksHandler, passthrough => [ { params => 'order=created_at' } ], }
		);

		# Menu entry 'Search'
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_SEARCH'), type => 'search',
			url  => \&tracksHandler, passthrough => [ { params => 'order=hotness' } ], }
		);

		# Menu entry 'Tags'
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_TAGS'), type => 'search',
			url  => \&tracksHandler, passthrough => [ { type => 'tags', params => 'order=hotness' } ], }
		);

		# Menu entry 'Playlists'
		push(@$callbacks,
		{ name => string('PLUGIN_SQUEEZECLOUD_PLAYLIST_SEARCH'), type => 'search',
			url  => \&tracksHandler, passthrough => [ { type => 'playlists', parser => \&_convertListOfSoundcloudPlaylistsToSlimserverPlalistsList } ] }
		);

		# Menu entry to enter an URL manually
		push(@$callbacks,
			{ name => string('PLUGIN_SQUEEZECLOUD_URL'), type => 'search', url  => \&urlHandler, }
		);
	} else {
		push(@$callbacks,
			{ name => string('PLUGIN_SQUEEZECLOUD_SET_API_KEY'), type => 'text' }
		);
	}

    # Add the menu entries from the menu array. It is responsible for calling
    # the correct method (url) and passing any parameters.
	$callback->($callbacks);
}

# Always end with a 1 to make Perl happy
1;
