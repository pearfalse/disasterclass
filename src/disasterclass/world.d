// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.world;

/// Provides high-level management of a Minecraft world.

import disasterclass.support;
import disasterclass.region;
import disasterclass.nbt;
import disasterclass.chunk;
public import disasterclass.vectors;

import std.zlib;
import std.file;
import std.path;
import std.stdio;
import std.algorithm;
import std.range;
import std.format;
import std.conv;
import std.datetime;
import std.typecons;
import std.math : floor, ceil;

public import std.array : front, empty, popFront; // for OrderedRegionRange, which is really an array

enum Dimension : byte
{
	Overworld = 0,
	Nether = -1,
	End = 1,
}

bool isValidDimension(Dimension d)
{
	return (d >= Dimension.Nether) && (d <= Dimension.End);
}
unittest
{
	assert(isValidDimension(Dimension.Overworld));
	assert(isValidDimension(Dimension.Nether));
	assert(isValidDimension(Dimension.End));
	assert(!isValidDimension(cast(Dimension) 15));
}

/***
	Handles an entire Minecraft world, all three dimensions. This is the first port of call for any operations to a world.

	$(D_KEYWORD World), like $(I Disasterclass) as a whole, is not designed for adding or removing chunks or regions; it will only transform existing chunks.

	This class is single-threaded.
*/
class World
{
	/***
		Constructs a handle for a whole Minecraft world. It unpacks level.dat, and makes $(D_KEYWORD Region) objects for every Anvil-format region file it finds for Overworld, Nether and End chunks.

		World maintains a global cache of all $(D_KEYWORD Chunk) objects for its world's chunks. This works as a circular buffer of references, with the oldest chunk getting unloaded (and saved back to the region file if modified).

		Throws: Exception or subclass on discovering malformed world data.

	*/
	this(in char[] path)
	{
		enforce(isDir(path), "Supplied Minecraft world folder (%s) is not a folder".format(path));
		mPath = path.idup;

		// load level.dat, get world name
		auto builtPath = buildPath(this.mPath, "level.dat");
		auto level_datZ = std.file.read(builtPath);
		//debug stderr.writefln("level_datZ is %d bytes", level_datZ.length);

		const(ubyte)[] level_dat;
		{
			// free function std.zlib.uncompress expects zlib-format data; won't check for gzip
			scope unc = new std.zlib.UnCompress(HeaderFormat.gzip);
			auto decompressed = unc.uncompress(level_datZ);
			decompressed ~= unc.flush();
			level_dat = cast(const(ubyte)[]) decompressed;			
		}

		levelRootNode = new NBTNode(level_dat);
		mName = levelRootNode.compoundValue["Data"].compoundValue["LevelName"].stringValue;

		// Now create Region objects
		foreach (dim ; [Dimension.Overworld, Dimension.Nether, Dimension.End]) {
			//debug stderr.writefln("Making regions for dimension %s", dim);
			Region.makeRegions(this, dim);
			this.buildOrderedRegionList(dim);
		}

	}

	@property string path() const { return mPath; }
	@property string name() const { return mName; }

	@property string name(string newName)
	{
		levelRootNode["Data"]["LevelName"].stringValue = newName;
		mName = newName;

		return newName;
	}

	NBTNode levelRootNode;

	/// Returns the number of chunks in the given dimension of this world.
	int numberOfChunks(Dimension dim = Dimension.Overworld) const
	in {
		assert(isValidDimension(dim));
	}
	body
	{
		const(Region[CoordXZ])* rmap = void;
		final switch (dim) {
			case Dimension.Overworld: rmap = &mAllRegionsOverworld; break;
			case Dimension.Nether   : rmap = &mAllRegionsNether   ; break;
			case Dimension.End      : rmap = &mAllRegionsEnd      ; break;
		}
		return reduce!"a + b"(0, (*rmap).byValue().map!"a.numberOfChunks"());
	}

	/***
		Returns the $(D_KEYWORD Region) for a given $(D_KEYWORD CoordXZ) and $(Dimension), or $(D_KEYWORD null) if no region exists.
	*/
	Region regionForChunk(CoordXZ chunkCoord, Dimension dimension)
	in {
		assert(dimension.isValidDimension());
	}
	body
	{
        scope(failure) stderr.writefln("Dimension that failed was %s", dimension);
		CoordXZ xz = chunkCoord >> 5;
		Region[CoordXZ]* allRegions = regionMapForDimension(dimension);
		
		auto r = (*allRegions).get(xz, null);
		//enforce(r, "No defined region for chunk %s".format(chunkCoord));
		//debug stderr.writefln("Chunk at coord %s found in region %s.".format(chunkCoord, r ? r.id.to!string() : "[none]"));
		return r;
	}

	/// Returns true iff this world has a chunk in the given dimension at the given co-ordinates.
	bool hasChunkAt(CoordXZ chunkCoord, Dimension dimension)
	{
		auto r = this.regionForChunk(chunkCoord, dimension);
		if (r is null) return false;

		return r.hasChunkAt(chunkCoord.regionSubCoord);
	}

	/// Loads a chunk's NBT from the requisite region file. Returns a null array if the chunk does not exist.
	ubyte[] loadChunkNBT(CoordXZ chunkCoord, Dimension dimension)
	{
		auto region = regionForChunk(chunkCoord, dimension);
		if (!region) return null;
		return region.decompressChunk(chunkCoord.regionSubCoord);
	}

	/// Saves a chunk's NBT to the requisite region file.
	void saveChunkNBT(CoordXZ chunkCoord, const(ubyte)[] chunkStream, Dimension dimension)
	{
		auto region = this.regionForChunk(chunkCoord, dimension);
		assert(region, "Attempted to write chunk NBT to non-existent region");
		region.writeChunk(chunkCoord, chunkStream);
	}

	void updateTimestamp()
	{
		NBTNode tsNode = levelRootNode["Data"]["LastPlayed"];
		enforce(tsNode.tagID == TagID.TAG_Long);

		tsNode.longValue = cast(long) (Clock.currTime().toUnixTime()) * 1000; // strange, but true
	}

	void saveLevelDat(string appendToName = null)
	{
		if (appendToName) {
			auto levelName = levelRootNode["Data"]["LevelName"];
			enforce(levelName.stringValue);
			levelName.value.stringValue ~= ' ' ~ appendToName;
		}
		auto stream = levelRootNode.flatten(false);
		scope gzipper = new Compress(HeaderFormat.gzip);
		auto gzdata = gzipper.compress(stream);
		gzdata ~= gzipper.flush();
		std.file.write(buildPath(mPath, "level.dat"), gzdata);
	}

	/***
		Returns the north, south, west and east limits of the world in chunk coordinates.
	*/
	Extents chunkExtents(Dimension dim) const
	{
		if (!numberOfChunks(dim)) return Extents(0, 0, 0, 0);

		return (*orderedRegionListForDimension(dim)).map!"a.chunkExtents()"().reduce!"a + b"();
	}
	alias chunkExtents extents;

	/***
		Returns an unordered range that iterates over a world's $(D_PARAM Region)s.
	*/
	auto byRegion(Dimension dim)
	{
		return regionMapForDimension(dim).byValue();
	}

	/***
		Returns a range that iterates over all regions in dimension $(D_PARAM dim) of this world. This range is ordered, and iterates north to south, then west to east.
	*/
	auto byRegionOrdered(Dimension dim)
	{
		return (*orderedRegionListForDimension(dim))[];
	}
	alias typeof((cast(World) null).byRegionOrdered(Dimension.Overworld)) OrderedRegionRange;

package:

	// Region object management
	Region[CoordXZ] mAllRegionsOverworld, mAllRegionsNether, mAllRegionsEnd;

	Region[] mOrderedRegionsOverworld, mOrderedRegionsNether, mOrderedRegionsEnd;

	/***
		Returns a pointer to the dimension's $(D_KEYWORD CoordXZ)-to-$(D_KEYWORD Region) map for this world.

		Throws: DisasterclassException if $(D_KEYWORD dim) is invalid.
	*/
    inout(Region[CoordXZ])* regionMapForDimension(Dimension dim) inout
    in {
        assert(dim.isValidDimension());
    }
    body
    {
    	assert(dim.isValidDimension(), "Invalid dimension passed to regionMapForDimension (%d)".format(cast(byte) dim));
        final switch (dim) {
            case Dimension.Overworld: return &mAllRegionsOverworld;
            case Dimension.Nether   : return &mAllRegionsNether;
            case Dimension.End      : return &mAllRegionsEnd;
        }
    }

private:

	/***
		Returns a pointer to the world's ordered $(D_KEYWORD Region) list for dimension $(D_KEYWORD dim).

		Throws: DisasterclassException if $(D_KEYWORD dim) is invalid.
	*/
	inout(Region[])* orderedRegionListForDimension(Dimension dim) inout
	{
		assert(dim.isValidDimension(), "Invalid dimension (%x) passed to orderedRegionListForDimension".format(cast(ubyte) dim));
		final switch (dim) {
			case Dimension.Overworld: return &mOrderedRegionsOverworld;
			case Dimension.Nether   : return &mOrderedRegionsNether;
			case Dimension.End      : return &mOrderedRegionsEnd;
		}
		assert(0);
	}

	/***
		Builds the ordered region list for dimension $(D_KEYWORD dim). Should be called from the ctor.
	*/
	void buildOrderedRegionList(Dimension dim)
	{
		auto srcMap = regionMapForDimension(dim), dstList = orderedRegionListForDimension(dim);

		dstList.length = srcMap.length;

		foreach (i, region ; zip(iota(0, dstList.length), regionMapForDimension(dim).byValue())) {
			(*dstList)[i] = region;
		}

		sort!("a.id < b.id")(*dstList);
	}

	string mPath, mName;
}
