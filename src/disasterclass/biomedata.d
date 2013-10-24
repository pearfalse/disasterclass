// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.biomedata;

import disasterclass.support;

import std.string : format;
import std.exception : enforce;

/// Return a biome's English name for a given biome type.
string biomeName(BiomeType biomeType)
{
	enforce(biomeType >= Biome.Unknown, "Invalid negative biome value (%d)".format(biomeType));
	if (biomeType >= 0 && biomeType < KnownBiomes.length) return KnownBiomes[biomeType];
	return null;
}

// TODO: some kind of compile-time guarantee that these are kept in sync

enum Biome : byte
{
	Unknown = -1,

	Ocean = 0,
	Plains,
	Desert,
	Extreme_Hills,
	Forest,
	Taiga,
	Swampland,
	River,
	Hell,
	Sky,
	Frozen_Ocean,
	Frozen_River,
	Ice_Plains,
	Ice_Mountains,
	Mushroom_Island,
	Mushroom_Island_Shore,
	Beach,
	Desert_Hills,
	Forest_Hills,
	Taiga_Hills,
	Extreme_Hills_Edge,
	Jungle,
	Jungle_Hills,

	Nether = Hell,
	End = Sky
}

/// Known biome names.
private string[] KnownBiomes = [
	"Ocean",
	"Plains",
	"Desert",
	"Extreme Hills",
	"Forest",
	"Taiga",
	"Swampland",
	"River",
	"Hell",
	"Sky",
	"Frozen Ocean",
	"Frozen River",
	"Ice Plains",
	"Ice Mountains",
	"Mushroom Island",
	"Mushroom Island Shore",
	"Beach",
	"Desert Hills",
	"Forest Hills",
	"Taiga Hills",
	"Extreme Hills Edge",
	"Jungle",
	"Jungle Hills"
];
