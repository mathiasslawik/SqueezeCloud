package Plugins::SqueezeCloud::Settings;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by David Blackman (first release), Robert Gibbon (improvements),
#   Daniel Vijge (improvements)
# See file LICENSE for full license details

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

sub name {
	return 'PLUGIN_SQUEEZECLOUD';
}

sub page {
	return 'plugins/SqueezeCloud/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.squeezecloud'), qw(apiKey playmethod));
}

1;
