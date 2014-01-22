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
	// temporary hack for 1.7
	if (biomeType > 39) return null;
	//enforce(biomeType >= Biome.Unknown, "Invalid negative biome value (%d)".format(biomeType));
	if (biomeType >= 0 && biomeType < KnownBiomes.length) return KnownBiomes[biomeType];
	return null;
}

// TODO: some kind of compile-time guarantee that these are kept in sync

enum Biome : ubyte
{
	Unknown = ubyte.max,

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
	Jungle_Edge,
	Deep_Ocean,
	Stone_Beach,
	Cold_Beach,
	Birch_Forest,
	Birch_Forest_Hills,
	Roofed_Forest,
	Cold_Taiga,
	Cold_Taiga_Hills,

	Mega_Taiga,
	Mega_Taiga_Hills,
	Extreme_Hills_plus,
	Savanna,
	Savanna_Plateau,
	Mesa,
	Mesa_Plateau_F,
	Mesa_Plateau,

	Sunflower_Plains = 129,
	Desert_M,
	Extreme_Hills_M,
	Flower_Forest,
	Taiga_M,
	Swampland_M,
	Ice_Plains_Spikes,
	Ice_Mountains_Spikes,

	Jungle_M = 149,
	Jungle_Edge_M = 151,

	Birch_Forest_M = 155,
	Birch_Forest_Hills_M,
	Roofed_Forest_M,
	Cold_Taiga_M,

	Mega_Spruce_Taiga = 160,
	Mega_Spruce_Taiga_Hills,
	Extreme_Hills_plus_M,
	Savanna_M,
	Savanna_Plateau_M,
	Mesa_Bryce,
	Mesa_Plateau_F_M,
	Mesa_Plateau_M,

	__last,

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
	"Jungle Hills",
	"Jungle Edge"
	"Deep Ocean",
	"Stone Beach",
	"Cold Beach",
	"Birch Forest",
	"Birch Forest Hills",
	"Roofed Forest",
	"Cold Taiga",
	"Cold Taiga Hills",

	"Mega Taiga",
	"Mega Taiga Hills",
	"Extreme Hills+",
	"Savanna",
	"Savanna Plateau",
	"Mesa",
	"Mesa Plateau F",
	"Mesa Plateau",

	"Sunflower Plains",
	"Desert M",
	"Extreme Hills M",
	"Flower Forest",
	"Taiga M",
	"Swampland M",
	"Ice Plains Spikes",
	"Ice Mountains Spikes",

	"Jungle M",
	"Jungle Edge M",

	"Birch Forest M",
	"Birch Forest Hills M",
	"Roofed Forest M",
	"Cold Taiga M",

	"Mega Spruce Taiga",
	"Mega Spruce Taiga Hills",
	"Extreme Hills+ M",
	"Savanna M",
	"Savanna Plateau M",
	"Mesa Bryce",
	"Mesa Plateau F M",
	"Mesa Plateau M"
];
