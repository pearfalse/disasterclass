// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.region;

/// Region file management.

import disasterclass.support;
import disasterclass.world;
import disasterclass.nbt;
import disasterclass.chunk;

import std.file;
import std.stdio;
import std.path;
import std.typecons;
import std.string;
import std.exception : enforce;
import std.datetime;
import std.range;
import std.format;
import std.algorithm;
import std.array : split, empty;
import std.math : ceil;
import std.bitmanip : nativeToBigEndian;
static import std.zlib;
import core.memory : GC;

debug {
	import core.thread : sleep;
	import core.time : dur;
}

package class Region
{
	/***
		Class that encapsulates a single .mca file.

	*/
	enum int
		maxCoordXZValue =  0x07ffffff, // anything greater than this doesn't cover a valid region
		minCoordXZValue = -0x08000000; // anything less than etc.

	private static __gshared immutable(ubyte[]) aSectorOfZeroes;
	shared static this()
	{
		Region.aSectorOfZeroes = new ubyte[Region.SECTOR_SIZE];
	}

	@property public inout(World) world() inout { return this.mWorld; }
	@property Dimension dimension() const { return mDimension; }
	@property CoordXZ id() const { return mId; }

	/// Is called by $(D makeRegions); you cannot make $(D Region) objects yourself.
	private this(World world, Dimension dimension, CoordXZ id, string mcaPath)
	in {
		assert(world !is null);
		//assert(mWorld.mAllRegions.get(id ,null) is null); // duplicate Regions for one .mca is an internal error
		assert(dimension.isValidDimension());
	} body
	{
		this.mId = id;
		this.mWorld = world;
		this.mDimension = dimension;

		this.mFile = File(mcaPath, "r+");

		// is the region big enough?
		mFile.seek(0, SEEK_END);
		auto regionSize = mFile.tell();
		enforce(regionSize >= SECTOR_SIZE*2, "Region file %s is too small to be valid".format(mFile.name));
		mFile.seek(0, SEEK_SET);

		auto rawOffsets = new ubyte[HEADER_COUNT*uint.sizeof];
		rawOffsets[] = ubyte.max;

		// read the headers
		mFile.rawRead(rawOffsets);
		mFile.rawRead(mRawTimestamps);
		assert(rawOffsets.length == HEADER_COUNT*uint.sizeof);
		assert(mRawTimestamps.length == HEADER_COUNT);

		// and decode offset uints into SectorRanges
		foreach (i ; 0..HEADER_COUNT) {
			auto enc = bigEndianDynamicToNative!uint(rawOffsets[i*4 .. (i+1)*4]);
			auto sr = SectorRange(enc >> 8, enc & 0xff);
			if (sr.len == 0) sr.front = 0; // we rely on this logic elsewhere
			mOffsets[i] = sr;
		}

		mLastSector = cast(uint) ceil(cast(real) (mFile.size) / SECTOR_SIZE);

		//debug stderr.writefln("Built region %s from path %s for dimension %s", mId, mcaPath, dimension);
	}

	/// Returns $(D true) iff a chunk exists at region sub-coord $(D_PARAM subCoord).
	bool hasChunkAt(CoordXZ subCoord) const
	in {
		assert(subCoord.isRegionSubCoord());
	}
	body
	{
		debug scope(failure) stderr.writefln("hasChunkAt failed on %s", subCoord);
		return mOffsets[(subCoord.z * 32) + subCoord.x].len != 0;
	}

	/// Returns the leafname of this .mca file.
	@property string filename() const pure nothrow {
		return mFile.name;
	}

	/***
		Creates $(D Region) objects for world $(D_PARAM world). You should not call this function yourself.
	*/
	static void makeRegions(World world, Dimension dimension)
	{
		string folder = world.path;
		if (dimension == Dimension.Overworld) {
			folder = buildPath(folder, "region");
		}
		else {
			folder = buildPath(folder, format("DIM%d", dimension), "region");
		}

		if (!exists(folder)) {
			debug stderr.writefln("Skipping dimension %s; region folder does not exist", dimension);
			return;
		}

		CoordXZ id;
		auto regionMap = world.regionMapForDimension(dimension);
		foreach (string mcaPath ; dirEntries(folder, SpanMode.shallow)) {
			string leaf = mcaPath[mcaPath.lastIndexOf('/')+1 .. $];
			// debug stderr.writefln("Entry %s", leaf);
			try {
				auto rLeafRead = formattedRead(leaf, "r.%d.%d.mca", &id.x, &id.z);
				if (rLeafRead != 2) continue; // not a .mca file. or, not one we can use
			}
			catch (Exception) {
				//debug stderr.writefln("%s is not a valid region file - ignoring", leaf);
				continue;
			}
			

			auto mcr = new Region(world, dimension, id, mcaPath);
			assert(id !in *regionMap); // no duplicates please
			(*regionMap)[id] = mcr;
		}
	}

	/// Returns the number of chunks in this region.
	@property int numberOfChunks() const
	{
		auto r = cast(int) std.algorithm.count!"a != 0"(mOffsets[].map!"a.front"()); // cast is safe: return value is never > 1024
		//debug stderr.writefln("Counted %d chunks in this region", r);
		return r;
	}

	/// Returns the minimum bounding box of this region in absolute chunk co-ordinates.
	Extents chunkExtents() const
	{
		auto regionCoords = Extents(
		mId.x * 32, (mId.x + 1) * 32,
		mId.z * 32, (mId.z + 1) * 32)[];

		// zip: pair a logical offset index with its abs. chunk coord
		// filter: skip the ones whose region offset is 0
		// map: jettison the offset, just gimme the coords
		auto range = zip(StoppingPolicy.requireSameLength, regionCoords, mOffsets[]).filter!"a[1].front != 0"().map!"a[0]"();
		static assert(is(typeof(range.front) == CoordXZ));

		auto tuple = reduce!("min(a, b.x)", "max(a, b.x)", "min(a, b.z)", "max(a, b.z)")(tuple(int.max, int.min, int.max, int.min), range);
		return Extents(tuple[0], tuple[1] + 1, tuple[2], tuple[3] + 1);
	}

	/***
		Decompresses an NBT stream from this region at the given sub-coord.

		This function makes no NBT compliance guarantees about the returned data, if it decompresses correctly.

		Returns: The uncompressed data if the chunk was found, otherwise null. This array is mutable and unaliased.
		Throws: ZlibException if the compressed data is corrupt.
	*/
	ubyte[] decompressChunk(CoordXZ chunkCoord)
	in {
		scope(failure) stderr.writefln("chunkCoord is %s (should be %s)", chunkCoord, chunkCoord & 31);
		assert(chunkCoord.x < 32);
		assert(chunkCoord.z < 32);

		assert(chunkCoord.x >= 0);
		assert(chunkCoord.z >= 0);
	}
	body
	{
		// get or create decoded chunk for this coord

		uint composite = (chunkCoord.z % 32)*32 + (chunkCoord.x % 32);
		assert(composite < mOffsets.length);

		//debug stderr.writefln("Seeking to offset (as int*) 0x%x.".format(composite));
		auto sr = mOffsets[composite];
		//debug stderr.writefln("Will read mca at byte offset 0x%x for %s.", sr.front * 0x1000, chunkCoord);
		if (sr.front == 0) {
			//debug stderr.writefln("Returning null because there's no chunk at %s/%s", mId, chunkCoord);
			return null;
		}

		enforce(sr.front >= 2, "Invalid location pointer for chunk %s; region file %s might be corrupted.".format(chunkCoord, mFile.name));

		mFile.seek(sr.front * SECTOR_SIZE, SEEK_SET);

		scope ubyte[] raw;
		raw.length = 5;
		mFile.rawRead(raw);
		//debug stderr.writefln("Read compressed chunk %s.", chunkCoord);
		assert(cast(uint[]) raw[0..4], "Length+1 is 0 bytes");
		enforce(raw[4] == 2, "Apparently not zlib-compressed chunk; format %d found in r%s, %s".format(raw[4], mId, chunkCoord)); // we only read zlib-compressed chunks
		uint chunkLength = bigEndianDynamicToNative!uint(raw[0..4]) - 1; // deliberate off-by-one in the format spec
		//debug stderr.writefln("Will get %s of decompressed chunk.", chunkLength.asCapacity());

		// load the compressed chunk into raw
		raw.length = sr.len * 0x1000;
		//mFile.seek(5, SEEK_CUR);
		mFile.rawRead(raw);

		return cast(ubyte[]) std.zlib.uncompress(raw, chunkLength);
	}

	/***
		Writes a chunk's NBT tree to this region.

		Throws: DisasterclassException if the compressed NBT stream is >= 4 GiB (which will realistically $(I never) happen, but we've covered it anyway).

	*/
	void writeChunk(Chunk chunk)
	in {
		assert((chunk.coord >> 5) == mId);
	} body
	{
		if (!chunk.modified) {
			//debug (dc13WriteChunk) stderr.writefln("Chunk %s not modified", chunk.coord);
			return;
		}
		debug scope(failure) stderr.writefln("writeChunk failed on chunk %s", chunk.coord);
		//debug(dc13WriteChunk) stderr.writef("Writing chunk %s to region %s: ", chunk.coord, mId);
		// prepare the variables we're gonna need
		auto subCoord = chunk.coord.regionSubCoord;
		auto chunkStream = enforce(chunk.rootNode.flatten(true));

		writeChunk(chunk.coord, chunkStream);
	}

	void writeChunk(CoordXZ chunkCoord, const(ubyte)[] chunkStream)
	{
		const(ubyte)[] zChunkStream = cast(const(ubyte)[]) std.zlib.compress(chunkStream);
		//assert(std.zlib.uncompress(zChunkStream.dup) == chunkStream);

		auto subCoord = chunkCoord.regionSubCoord;
		uint index = (subCoord.z * 32) + subCoord.x;

		// time to write the compressed chunk
		ubyte[5] chunkHeader = [0,0,0,0,2];
		version(D_LP64) enforce(zChunkStream.length <= uint.max, "Compressed chunk is > 4 GiB; Minecraft can't read this (what have you PUT in here?)");
		chunkHeader[0..4] = nativeToBigEndian!uint(cast(uint) zChunkStream.length + 1);

		
		auto sr = findGapToWriteChunk(subCoord, cast(uint) zChunkStream.length);
		//debug(dc13WriteChunk) stderr.writef("%s ", sr);

		mFile.seek(sr.front * SECTOR_SIZE);
		mFile.rawWrite(chunkHeader);
		mFile.rawWrite(zChunkStream);
		// and pad to 4 KiB
		uint rem = ( SECTOR_SIZE - (mFile.tell() & (SECTOR_SIZE - 1)) ) & (SECTOR_SIZE-1);
		if (rem) mFile.rawWrite(aSectorOfZeroes[0 .. rem]);

		// write the header offset
		mOffsets[index] = sr;
		mFile.seek(index * 4);
		mFile.rawWrite(nativeToBigEndian!uint((sr.front << 8) + sr.len));

		debug(dc13WriteChunk) {
			//stderr.writefln("region %s: index(bytes) = %x, offset = %x chunk = %s (sub %s), zcs = %x", mId, index*4, sr.front, chunk.coord, subCoord, zChunkStream.length);
		}

		// and the timestamp
		version(D_LP64) {
			uint thisTimestamp = cast(uint) (Clock.currTime().toUnixTime() & 0xffffffffU);
		}
		else {
			uint thisTimestamp = Clock.currTime().toUnixTime();
		}
		mRawTimestamps[index] = thisTimestamp;
		mFile.seek((index * 4) + SECTOR_SIZE);
		mFile.rawWrite(nativeToBigEndian!uint(thisTimestamp));

		debug this.validateSectorRanges();
	}

	/// Return a $(D_KEYWORD ChunkRange) suitable for this region.
	@property auto byChunk()
	{
		return ChunkRange(this);
	}

	/***
		Iterates over all chunks in this region, in order. Yields their chunk co-ordinates.
	*/
	struct ChunkRange
	{
		this(Region r)
		in {
			assert(r);
		}
		body
		{
			mRegion = r;
			mDimension = r.mDimension;
			// front could return null if there's no chunk at the first offset
			// this checks the offset directly (instead of calling front) to handle completely empty regions
			if (mRegion.mOffsets[(mCoord.z << 5) + mCoord.x].len == 0) popFront();
		}

		ChunkRange save()
		{
			ChunkRange cr = this;
			return cr;
		}

		/***
			Gets the chunk co-ord of the currently front chunk in this range.

			Returns: $(D_KEYWORD CoordXZ) rvalue;
		*/
		@property CoordXZ front()
		in {
			assert(mRegion, "mRegion is not front-able");
		}
		body
		{
			return (mRegion.mId * 32) + mCoord;
		}

		alias front frontCoord;

		void popFront()
		{
			assert(!this.empty);
			do {
				++mCoord.x;
				if (mCoord.x == 32) {
					++mCoord.z;
					mCoord.x = 0;
				}
			} while (mCoord.z < 32 && mRegion.mOffsets[(mCoord.z << 5) + mCoord.x].len == 0); // skip over non-existent chunks
			//debug stderr.writefln("popFront: mCoord = %s", mCoord);
		}

		@property bool empty()
		{
			return mCoord.z >= 32;
		}

	private:

		Region mRegion;
		Dimension mDimension;
		CoordXZ mCoord = CoordXZ(0,0);
	}

package:

	/// Helper function to decide where in the .mca a chunk of given size would be saved.
	SectorRange findGapToWriteChunk(CoordXZ subCoord, uint compressedChunkSize)
	in {
		assert(subCoord.isRegionSubCoord());
	} out(result) {
		assert(result.len >= 1);
		assert(result.front >= 2);
		//debug(dc13WriteChunk) stderr.writefln("%s: %s -> %s", subCoord, mOffsets[(subCoord.z<<5)+subCoord.x], result);
	}
	body
	{
		bool sectorIsClear(uint sector)
		{
			foreach (i, const ref sr ; mOffsets) {
				if (sector in sr) return false;
			}
			return true;
		}

		SectorRange body2(CoordXZ subCoord, uint compressedChunkSize)
		{
			auto zsize = cast(uint) ceil(cast(real) (compressedChunkSize + 5) / SECTOR_SIZE); // compressed chunk size + header in 4KiB sectors

			uint serialId = (subCoord.z << 5) + subCoord.x;
			auto existing = mOffsets[serialId];

			if (existing.front != 0) {
				assert(existing.len);
				// chunk already exists in region - can we overwrite the old one?
				if (zsize <= existing.len) {
					// yes! new chunk is the same size or smaller
					return SectorRange(existing.front, zsize);
				}
				// no, new chunk is bigger. but can we resize it in place?
				// iterate over the additional sectors, and check they're all free

				//const uint addSectorsStart = zsize - existing.len;
				//uint addSectors = addSectorsStart; // if this ever reaches zero, we have enough free sectors in-place
				//for (int iSectors = existing.end; iSectors <= (existing.front + zsize); --addSectors) {
				//	if (!sectorIsClear(iSectors++)) goto LnotInPlace;
				//}

				const uint addSectors = zsize - existing.len; // number of extra sectors to add
				uint nSectorsFree = 0;
				foreach (i ; 0..addSectors) {
					if (!sectorIsClear(existing.end + i)) break;
					++nSectorsFree;
				}
				// we have it! we have it right here, right now. use old front, new length
				if (nSectorsFree == addSectors) return SectorRange(existing.front, zsize);
			}

			LnotInPlace:
			//uint lastSector = cast(uint) ceil(cast(real) (mFile.size) / SECTOR_SIZE);
			alias mLastSector lastSector;

			uint rem = zsize;
			for (uint iSectors = 2; iSectors < lastSector; ) {
				if (sectorIsClear(iSectors++)) {
					--rem; // this was free
					//debug(dc13WriteChunk) stderr.writefln("Sector %d was free; rem now %d", iSectors-1, rem);
				}
				else rem = zsize; // found a blocker; can't place chunk here, so reset the counter
				if (rem == 0) {
					// as above, if this reches zero, all sectors are free! iSectors points to the .end
					//debug(dc13WriteChunk) stderr.writefln("Last sector %d free; placing SR of len %d here", iSectors-1, zsize);
					return SectorRange(iSectors - zsize, zsize);
				}
				// rem > 0, so keep iterating
			}
			// no insertable space; have to append
			//debug(dc13WriteChunk) stderr.writefln("Had to append");
			return SectorRange(lastSector, zsize);
		}

		auto sr = body2(subCoord, compressedChunkSize);
		mLastSector = max(sr.end, mLastSector);
		//debug(dc13WriteChunk) stderr.writefln("Chunk %s to sr %s; last sector is now %d", (mId<<5)+subCoord, sr, mLastSector);
		return sr;
	}

	/// Returns true iff chunk $(D_PARAM c) is paired with this region.
	bool opBinaryRight(string op : "in")(Chunk c) const {
		return (c.coord >> 5) == mId;
	}

	debug void validateSectorRanges()
	{
		// ensures that all SectorRanges are valid - non-overlapping, within the region limits

		static byte runCount = 0;
		++runCount;
		if (runCount < 16) return; // only run this every 16 chunks, for non-awful performance
		runCount = 0;

		// within the region limits
		foreach (ref const sr ; mOffsets) {
			assert(sr.front <  mLastSector);
			assert(sr.end   <= mLastSector);
		}

		// non-overlapping
		foreach (ia ; 0..HEADER_COUNT-1) {
			foreach (ib ; ia+1..HEADER_COUNT) {
				scope(failure) stderr.writefln("validateSectorRanges failed on: mOffsets[ia] = %s, mOffsets[ib] = %s", mOffsets[ia], mOffsets[ib]);

				// if either is <airquotes>null</airquotes>, there's nothing to compare
				if (mOffsets[ia].front == 0 || mOffsets[ib].front == 0) continue;

				assert(mOffsets[ia].front != mOffsets[ib].front); // this should never be true. just - never.

				if (mOffsets[ia].front < mOffsets[ib].front) {
					// mOffsets[ia] starts earlier, so needs to end before mOffsets[ib] begins
					assert(mOffsets[ia].end <= mOffsets[ib].front);
				}
				else {
					assert(mOffsets[ib].end <= mOffsets[ia].front);
				}

			}
		}

		// looks good. but no way am i having 4 }s in a row, so here's a comment.
	}

	enum HEADER_COUNT = 1024, SECTOR_SIZE = 4096;

	/// Encapsulates the starting position and length of a compressed chunk in a region, expressed in 4 KiB sectors.
	struct SectorRange
	{
		uint front, len;
		@property uint end() const { return front + len; }
		bool opBinaryRight(string op : "in")(uint lhs) const {
			return (lhs >= front && lhs < end);
		}

		unittest
		{
			auto sr = SectorRange(10, 10);
			assert(sr.end == 20);
			assert(10 in sr);
			assert(11 in sr);
			assert(19 in sr);
			assert(20 !in sr);
			assert(9000 !in sr);
			assert(1 !in sr);
		}
	}

private:
	File mFile;
	World mWorld;
	Dimension mDimension = Dimension.Overworld;
	CoordXZ mId;

	SectorRange[HEADER_COUNT] mOffsets; // organised by header (i.e. region coord)
	uint[HEADER_COUNT] mRawTimestamps;

	uint mLastSector; // used by findGapToWriteChunk - DO NOT MESS WITH

	/// Constructor to make dummy $(D_SYMBOL Region). Available to unit test code only.
	version(unittest) this() {}
}

unittest
{
	scope r = new Region();

	/* to test findGapToWriteChunk, fake these SectorRanges:
	0 = (2, 1)
	-- gap of 1 --
	1 = (4, 2)
	-- gap of 2 --
	3 = (8, 4) // yes, 3. this algorithm is supposed to be independent of the array order (which links to chunk coords, not region offsets)
	-- gap of 4 --
	2 = (16, 8)
	*/

	alias Region.SectorRange SectorRange;
	alias Region.SECTOR_SIZE SECTOR_SIZE;

	scope(failure) stderr.writeln(r.mOffsets[0..32]);

	r.mOffsets[0] = SectorRange( 2, 1);
	r.mOffsets[1] = SectorRange( 4, 2);
	r.mOffsets[3] = SectorRange( 8, 4);
	r.mOffsets[2] = SectorRange(16, 8);

	// first, the ones where it fits in the same size
	assert(r.findGapToWriteChunk(CoordXZ(0,0), SECTOR_SIZE*1 - 5) == SectorRange(2, 1));
	assert(r.findGapToWriteChunk(CoordXZ(1,0), SECTOR_SIZE*2 - 5) == SectorRange(4, 2));
	assert(r.findGapToWriteChunk(CoordXZ(3,0), SECTOR_SIZE*4 - 5) == SectorRange(8, 4));
	assert(r.findGapToWriteChunk(CoordXZ(2,0), SECTOR_SIZE*8 - 5) == SectorRange(16,8));

	// and expanding in place
	assert(r.findGapToWriteChunk(CoordXZ(0,0), SECTOR_SIZE*2  - 5) == SectorRange (2, 2));
	assert(r.findGapToWriteChunk(CoordXZ(1,0), SECTOR_SIZE*4  - 5) == SectorRange (4, 4));
	assert(r.findGapToWriteChunk(CoordXZ(3,0), SECTOR_SIZE*8  - 5) == SectorRange (8, 8));
	assert(r.findGapToWriteChunk(CoordXZ(2,0), SECTOR_SIZE*16 - 5) == SectorRange(16,16));

	// forcing one up
	assert(r.findGapToWriteChunk(CoordXZ(0,0), SECTOR_SIZE*3 - 5) == SectorRange (12, 3));
	assert(r.findGapToWriteChunk(CoordXZ(1,0), SECTOR_SIZE*5 - 5) == SectorRange (24, 5));

	auto cr = r.byChunk;
	assert(cr.front == cr.save().front);

}

/// Returns true iff $(D_CODE 0 < c < 32) for both $(D_KEYWORD x) and $(D_KEYWORD z) in $(D_KEYWORD c).
bool isRegionSubCoord(CoordXZ c)
{
	return (c.x >= 0 && c.x < 32 && c.z >= 0 && c.z < 32);
}
