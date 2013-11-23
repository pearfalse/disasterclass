// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.chunk;

/// Chunk handling and processing.

import disasterclass.nbt;
import disasterclass.support;
import disasterclass.world;
import disasterclass.data;
import disasterclass.threads : getChunkAt, chunkNeighbours;

import std.datetime;
import std.zlib;
import std.conv;
import std.algorithm, std.range;
import std.typecons;
//import std.traits;
import std.exception : enforce;
import std.array : uninitializedArray;
import std.stdio;
import std.random;
import std.math : ceil;

debug {
	import std.bitmanip;
}

/++
	Holds a decoded chunk in memory. Currently preserves the full NBT tree as-is, although this may change for block data in future.
+/

package final class Chunk
{
	@property inout(NBTNode)     rootNode()  inout { return mRootNode; }
	@property ref const(SysTime) timestamp() const { return mTimestamp; }
	@property CoordXZ            coord()     const { return mCoord; }
	@property Dimension          dimension() const { return mDimension; }

	enum uint
	Length = 16,
	Width = 16,
	Height = 256,
	SectionHeight = 16,
	NBlocks = 16*16*256,
	AverageMemoryFootprint = 0
	;

	static Mt19937 rng;
	static shared uint rngSeed;

	struct BlockArray(T, uint X, uint Y, uint Z)
	{
		T[X*Y*Z] array;
		alias array this;

		T opIndex(uint x, uint y, uint z) const
		in {
			assert(x < X, "BlockArray.opIndex x out of bounds: "~x.to!string()~" >= "~X.to!string());
			assert(y < Y, "BlockArray.opIndex y out of bounds: "~y.to!string()~" >= "~Y.to!string());
			assert(z < Z, "BlockArray.opIndex z out of bounds: "~z.to!string()~" >= "~Z.to!string());
		}
		body
		{
			return array[(y*Z+z)*X+x];
		}

		void opIndexAssign(T v, uint x, uint y, uint z)
		in {
			assert(x < X, "BlockArray.opIndexAssign x out of bounds: "~x.to!string());
			assert(y < Y, "BlockArray.opIndexAssign y out of bounds: "~y.to!string());
			assert(z < Z, "BlockArray.opIndexAssign z out of bounds: "~z.to!string());
		}
		body
		{
			array[(y*Z+z)*X+x] = v;
		}

		T[] opSlice()
		{ return array[]; }

		T[] opSliceAssign(in T[] rhs, uint begin, uint end)
		{
			return (array[begin .. end] = rhs[]);
		}

		ref BlockArray!(T, X, Y, Z) opAssign(ref const BlockArray!(T, X, Y, Z) that)
		{
			this.array[] = that.array[];
			return this;
		}

		int opApply(int delegate(uint, uint, uint, ref T) dg)
		{
			uint dx = 0, dy = 0, dz = 0;

			foreach (ref slot ; this.array) {
				auto r = dg(dx, dy, dz, slot);
				if (r != 0) return r;

				if (++dx == X) {
					dx = 0;
					if (++dz == Z) {
						dz = 0;
						++dy;
					}
				}
			}

			return 0;
		}
	}
	
	unittest {
		BlockArray!(int, 2, 2, 2) ba;

		ba[0, 1, 0] = 9;
		assert(ba[0, 1, 0] == 9);
		assert(ba.array[4] == 9);
	}
	alias BlockArray!(ubyte, 16, 256, 16) ChunkArray;

	BlockArray!(BlockID, 16, 256, 16) blocks;
	ChunkArray blockData, skyLight, blockLight;

	bool modified = false;

	/++
		Create a new decoded chunk. The constructor asks for the raw NBT to ensure it can deallocate nodes it rearranges.
	+/
	this(CoordXZ coord, Dimension dimension, in ubyte[] rawNBT)
	{
		this.mRootNode = new NBTNode(rawNBT);
		//this.mDimension = dimension;
		mRootNode = mRootNode["Level"]; // get the named root; ignore its siblings it might (but shouldn't) have
		mCoord = CoordXZ(mRootNode["xPos"].intValue, mRootNode["zPos"].intValue);

		mHeightMap = mRootNode["HeightMap"].uintArrayValue;

		enforce(mCoord == coord, "Chunk coord %s doesn't match given coord %s".format(mCoord, coord));

		// create shortcut lookup of what sections exist
		foreach (secNode ; mRootNode["Sections"].listValue) {
			ubyte comp = cast(ubyte) secNode["Y"].byteValue;
			enforce(comp < 16, "Section %d is invalid".format(comp));
			mSections[comp] = secNode;

			enforce(secNode["Blocks"].byteArrayValue.length == 4096,
				"Section array Blocks is invalid length; should be 4096, is %d".format(secNode["Blocks"].byteArrayValue.length));
			enforce(secNode["Data"].byteArrayValue.length == 2048,
				"Section array Data is invalid length; should be 2048, is %d".format(secNode["Data"].byteArrayValue.length));
			enforce(secNode["SkyLight"].byteArrayValue.length == 2048,
				"Section array SkyLight is invalid length; should be 2048, is %d".format(secNode["SkyLight"].byteArrayValue.length));
			enforce(secNode["BlockLight"].byteArrayValue.length == 2048,
				"Section array BlockLight is invalid length; should be 2048, is %d".format(secNode["BlockLight"].byteArrayValue.length));
		}

		combineSectionArrays();

	}

	/// Returns the block ID and data value of the block at a given co-ordinate. If the index is for a neighbouring chunk and no chunk is present, NoBlock is returned.
	BlockIDAndData opIndex(int x, int y, int z)
	{
		// ensure these are per-chunk co-ords
		uint
		xh = x & ~(Chunk.Length - 1), xl = x & (Chunk.Length - 1),
		zh = z & ~(Chunk.Length - 1), zl = z & (Chunk.Length - 1);

		// We don't support indirect chunk access yet
		if (xh || zh || y < 0) {
			return NoBlock;
		}

		auto index = (y*Length+zl)*Length+xl;
		return BlockIDAndData(blocks.array[index], blockData.array[index]);
	}

	/// ditto
	BlockIDAndData opIndex(CoordXYZ coord)
	{
		return opIndex(coord.x, coord.y, coord.z);
	}

	/// Set the ID and data of the block at a given co-ordinate.
	void opIndexAssign(BlockIDAndData biad, int x, int y, int z)
	{
		// ensure these are per-chunk co-ords
		uint
		xh = x & ~(Chunk.Length - 1), xl = x & (Chunk.Length - 1),
		zh = z & ~(Chunk.Length - 1), zl = z & (Chunk.Length - 1);

		// TODO: indirect chunk access
		debug {
			string dmsg = "Indirect chunk access is not supported (%d, %d)";
			assert(!xh, dmsg.format(x, z));
			assert(!zh, dmsg.format(x, z));
		}

		auto index = (y*Length+zl)*Length+xl;
		blocks.array[index] = biad.id;
		// if you run the BlockID-only wrapper of opIndexAssign, data is 0xff to indicate `don't change`
		if (biad.data <= 0x0f) blockData.array[index] = biad.data;
	}

	/// ditto
	void opIndexAssign(BlockID id, int x, int y, int z)
	{
		this.blocks   [x, y, z] = id;
		this.blockData[x, y, z] = 0u;
	}

	/// Returns the approximate memory footprint of this chunk and its NBT data in bytes.
	@property size_t memoryFootprint() const
	{
		return this.sizeof + mRootNode.memoryFootprint;
	}

	/// Flattens a chunk into an NBT stream. You should call this instead of Chunk.rootNode.flatten(), or you may
	/// lose changes to the chunk's data.
	ubyte[] flatten()
	{
		// there's no wrapAnonymousCompound param because that's always true for chunks
		if (this.modified) splitToSectionArrays();
		return mRootNode.flatten(true);
	}

	/++
		Allows iterating over this chunk's blocks and counterpart data. This iteration is read-only.
	+/
	int opApply(int delegate(ref BlockID, ref BlockData data) dg)
	{
		int r;

		version(none) {
			BlockID dbgBlocksOr = cast(BlockID) reduce!"a | b"(0u, blocks[]);
			BlockData dbgDataOr = cast(BlockData) reduce!"a | b"(0u, blockData[]);

			stderr.writefln("Chunk %s reductions: blocks = %d, data = %d", mCoord, dbgBlocksOr, dbgDataOr);
		}

		assert(blocks.length == blockData.length);
		foreach (block, data ; lockstep(blocks[], blockData[])) {
			r = dg(block, data);
			if (r) return r;
		}

		return 0;
	}

	static void seedThisThread(uint seedValue)
	{
		rng.seed(seedValue);
	}

	/// Recalculates the world's lighting. Should be done after all other processing, partly because it is $(I extremely) slow.
	void relight2()
	{
		// dc13MultiBlock-aware relighting
		/*
			THIS IS THE PROCESS:
			1) get all immediate neighbours (<= 8)
			2) for self and neighbours: if lighting state < HeightMapAnd15: do pass 1
			pass 1 is defined as:
				• recalculate height map
				• replace SkyLight and BlockLight with 15s and 0s (i.e. no dissipation)
			3) do pass 2 for sky light
			pass 2 is defined as:
				• dissipation on ghost layer
				• blend down
		*/
		if (this.mLightRecalcState == LightRecalcState.LocalComplete) return;

		debug(dc13Lighting) stderr.writefln("Lighting chunk %s...", mCoord);

		foreach (n ; chunkNeighbours[].filter!"a !is null"()) n.relightImpl_pass1();
		this.relightImpl_pass2((Chunk c) => &c.blockLight);
		this.relightImpl_pass2((Chunk c) => &c.skyLight);
		this.mLightRecalcState = LightRecalcState.LocalComplete;

		this.modified = true;
	}

	/// Rebuilds the chunk's height map.
	void rebuildHeightMap()
	{
		foreach (ubyte z ; 0..16) foreach (ubyte x ; 0..16) Ly: for (int y = 255; y > 0; --y) {
			auto isTransparent = Blocks[blocks[x, cast(ubyte) y, z]].flags & Flags.Transparent;
			//auto isOpaque = this[x, y, z].id; // count all non-air as opaque for now
			if (!isTransparent) {
				//debug stderr.writefln("HM Chunk:%s/%d,%d:%d", mCoord, x, z, y);
				mHeightMap[(z*16)+x] = y + 1;
				debug(dc13Lighting) {
					//this[x, y, z] = BlockIDAndData(BlockType.Sponge, cast(BlockData) 0u);
				}
				break Ly;
			}
		}

		debug(none) {
			ulong dbgSum = reduce!"a + b"(0, mHeightMap);
			uint dbgMin = reduce!"min(a, b)"(uint.max, mHeightMap), dbgMax = reduce!"max(a, b)"(0, mHeightMap);
			stderr.writefln("HEIGHTMAP avg %d min %d max %d", dbgSum / mHeightMap.length, dbgMin, dbgMax);
		}
	}

private:
	// Reprocessed chunk sections
	NBTNode mEntities, mTileEntities, mTileTicks;
	uint[] mHeightMap;
	// «type» mLastUpdate; TODO
	// TerrainPopulated will remain unchanged.
	//BiomeType[Width*Height] mBiomeData = void;

	NBTNode       mRootNode;
	SysTime       mTimestamp;
	CoordXZ       mCoord;
	Dimension     mDimension;

	/// Tracks the state of lighting recalculation.
	enum LightRecalcState
	{
		Stale = 0,      /// Lighting not updated.
		HeightMapAnd15, /// HeightMap recalc'd, 15s and 0s of BlockLight and SkyLight set
		LocalComplete   /// Dissipation for local sources complete
	}
	LightRecalcState mLightRecalcState = LightRecalcState.Stale;

	// Iteration helpers
	NBTNode[16] mSections;
	deprecated static immutable sEmptySectionRange = std.range.repeat!BlockID(0, Width*Length*SectionHeight);

	static assert(blocks.array.length    == blockData.array.length );
	static assert(blockData.array.length == skyLight.array.length  );
	static assert(skyLight.array.length  == blockLight.array.length);

	void combineSectionArrays()
	{
		debug(none) ulong dbgNotAir;

		// combine blocks split in sections into contiguous arrays
		foreach (i, sec ; mSections) {
			if (!sec) continue;

			size_t
			byteSliceA =  i   *Chunk.Length*Chunk.Width*Chunk.SectionHeight,
			byteSliceB = (i+1)*Chunk.Length*Chunk.Width*Chunk.SectionHeight;
			assert(byteSliceB - byteSliceA == 4096);

			//blocks[byteSliceA .. byteSliceB] = sec.byteArrayValue[];
			auto bavBlocks = sec["Blocks"].ubyteArrayValue;
			uint si = 0;
			foreach (bi ; byteSliceA .. byteSliceB) {
				blocks.array[bi] = bavBlocks[si++];
				debug(none) if (blocks.array[bi] != 0) ++dbgNotAir;
			}

			assert(blockData .array[byteSliceA .. byteSliceB].length == 4096);
			assert(skyLight  .array[byteSliceA .. byteSliceB].length == 4096);
			assert(blockLight.array[byteSliceA .. byteSliceB].length == 4096);

			//assert(blockLight[].all!"a <= 0x0f"(), "BlockLight contains bytes with invalid nibbles");

			unpackNibbles(sec["Data"]      .ubyteArrayValue, blockData .array[byteSliceA .. byteSliceB]);
			unpackNibbles(sec["SkyLight"]  .ubyteArrayValue, skyLight  .array[byteSliceA .. byteSliceB]);
			unpackNibbles(sec["BlockLight"].ubyteArrayValue, blockLight.array[byteSliceA .. byteSliceB]);
		}

		//debug stderr.writefln("Chunk %s: %d not air", mCoord, dbgNotAir);
	}

	void splitToSectionArrays()
	{
		// do the opposite of combineSectionArrays

		// find where the last block is, and turn that into a maximum section
		size_t lastBlock = blocks[].length - blocks[].retro().countUntil!"a != 0"();
		ubyte nSections = 0; size_t thresh = 0;
		while (nSections < 16) {
			++nSections;
			thresh += (Length*Width*SectionHeight);
			if (thresh > lastBlock) break;
		}

		bool didMakeNewSections = false;
		foreach (ubyte i ; 0 .. nSections) {
			if (!mSections[i]) {
				makeNewSection(i);
				didMakeNewSections = true;
			}

			NBTNode sec = mSections[i];

			size_t
			byteSliceA =  i   *Chunk.Length*Chunk.Width*Chunk.SectionHeight,
			byteSliceB = (i+1)*Chunk.Length*Chunk.Width*Chunk.SectionHeight;

			//sec.byteArrayValue[] = blocks[byteSliceA .. byteSliceB];
			auto bavBlocks = sec["Blocks"].ubyteArrayValue;
			uint si = 0;
			foreach (bi ; byteSliceA .. byteSliceB) {
				bavBlocks[si++] = cast(ubyte) (blocks.array[bi] & 0xff);
			}
			blockData .array[byteSliceA .. byteSliceB].packNibbles(sec["Data"]      .ubyteArrayValue);
			skyLight  .array[byteSliceA .. byteSliceB].packNibbles(sec["SkyLight"]  .ubyteArrayValue);
			blockLight.array[byteSliceA .. byteSliceB].packNibbles(sec["BlockLight"].ubyteArrayValue);
		}

		if (didMakeNewSections) {
			// reset the Sections list
			NBTNode sections = mRootNode["Sections"];
			NBTNode[] newList = mSections[].filter!"a !is null"().array();
			assert(countUntil!"a is null"(newList) == -1, "there are nulls in the new sections list");
			//debug stderr.writefln("newList: %s", newList);
			sections.listValue.nbtnodes = newList;
		}

	}


	// Private methods
	NBTNode makeNewSection(ubyte index)
	in {
		assert(index < 16);
		assert(!mSections[index]);
	}
	body
	{
		debug(none) stderr.writefln("Making new section %d for chunk %s", index, mCoord);
		NBTNode
		nodeY          = new NBTNode,
		nodeBlocks     = new NBTNode,
		nodeData       = new NBTNode,
		nodeBlockLight = new NBTNode,
		nodeSkyLight   = new NBTNode
		;

		nodeY.byteValue               = cast(byte) index;
		nodeBlocks.byteArrayValue     = new byte[Length*Width*SectionHeight    ];
		nodeData.byteArrayValue       = new byte[Length*Width*SectionHeight / 2];
		nodeBlockLight.byteArrayValue = new byte[Length*Width*SectionHeight / 2];
		nodeSkyLight.byteArrayValue   = new byte[Length*Width*SectionHeight / 2];

		auto rootNode = new NBTNode;
		rootNode.tagID = TagID.TAG_Compound;
		rootNode["Y"] = nodeY;
		rootNode["Blocks"] = nodeBlocks;
		rootNode["Data"] = nodeData;
		rootNode["BlockLight"] = nodeBlockLight;
		rootNode["SkyLight"] = nodeSkyLight;

		mSections[index] = rootNode;

		return rootNode;
	}

	void relightImpl_pass1()
	{
		if (this.mLightRecalcState >= LightRecalcState.HeightMapAnd15) {
			//debug(dc13Lighting) stderr.writef("[not pass1-ing %s]", me.coord);
			return;
		}

		this.rebuildHeightMap();

		// set 15s and 0s on SkyLight
		foreach (index, colThreshold ; zip(
			iota(0, NBlocks),                    // the raw SkyLight array, YZX
			this.mHeightMap[].cycle()             // the HeightMap forever, ZX
		)) {
			this.skyLight[][index] = ((index / 256) < colThreshold) ? 0 : 15;
		}

		//debug(dc13Lighting) stderr.writef("BL %s ", me.coord);
		// set source levels on BlockLight
		foreach (ref blockType, ref unit ; lockstep(this.blocks[], this.blockLight[])) {
			unit = (Blocks[blockType].flags & Flags.BlockLightLevel_M) >> Flags.BlockLightLevel_S;
			assert(unit < 16);
		}

		debug(none) stderr.writefln("BL is > 0 for %d block(s)", this.blockLight[].count!"a != 0"());

		this.mLightRecalcState = LightRecalcState.HeightMapAnd15;
		this.modified = true;
	}

	void relightImpl_pass2(scope ChunkArray* delegate(Chunk) arrayFinder)
	{
		static size_t index(int x, int y, int z)
		{
			// hardcoded to a NeighbourRadius of 1
			int x2 = ((x + 16) >> 4) - 1;
			int z2 = ((z + 16) >> 4) - 1;
			return 4 + (z2 * 3) + x2;
		}

		ChunkArray*[9] nbArrays = void;
		static ChunkArray _noChunkProxyArray;

		// nbArrays maps each neighbour chunk to a ptr to its respective block array
		auto _r = chunkNeighbours[].map!((Chunk c) => c !is null ? arrayFinder(c) : &_noChunkProxyArray)();
		assert(_r.length == 9);
		_r.copy(nbArrays[]);

		auto cba = nbArrays[4]; assert(cba !is &_noChunkProxyArray);

		foreach (pass ; 1..15) {

			foreach (y ; 0..256) foreach (z ; (-pass)..(16+pass)) foreach (x ; (-pass)..(16+pass)) {
				auto thisCentre = nbArrays[index(x, y, z)];
				auto thisBlockId = (*thisCentre)[x & 15, y, z & 15];
				(*thisCentre)[x & 15, y, z & 15] = cast(ubyte) max(
					(*nbArrays[index(x-1, y, z)])[(x-1) & 15, y, z & 15] - 1,
					(*nbArrays[index(x+1, y, z)])[(x+1) & 15, y, z & 15] - 1,
					(*nbArrays[index(x, y, z-1)])[x & 15, y, (z-1) & 15] - 1,
					(*nbArrays[index(x, y, z+1)])[x & 15, y, (z+1) & 15] - 1,
					(*thisCentre)[x & 15, min(y+1, 255), z & 15] - 1,
					(*thisCentre)[x & 15, max(y-1, 0  ), z & 15] - 1,
					(*thisCentre)[x & 15, y, z & 15]
				);
			}

		} // foreach pass
	}

}

unittest
{
	CoordXZ a = CoordXZ(-33, -2), b = CoordXZ(-1, -2);
}

/++

	Extremely basic, hardcoded StoneAge filter for $(I Disasterclass)'s true purpose. This filter:
	$(UL
		$(LI converts cobblestone to mossy cobblestone;)
		$(LI converts plain stone to cobblestone;)
		$(LI converts all stone brick to plain stone.)
	)

	All probability and randomness is redundant code at this stage; this function converts 100% of blocks.

+/
void basicStoneAge(Chunk c)
{
	//debug(dc13WriteChunk) stderr.writef("bsa %s", mCoord);

	// Filter thresholds for random numbers (these numbers themselves are pretty arbitrary)
	enum uint
	ThreshBrickToCracked = 0xaa000000U,
	ThreshBrickToMoss    = 0x18000000U,
	ThreshBrickToPlain   = 0x03000000U,
	ThreshPlainToCobble  = 0x88000000U,
	ThreshCobbleToMossy  = 0x1f000000U,
	ThreshRose           = 0x018a37afU,
	ThreshDandelion      = 0x07688184U,
	ThreshNoGrass        = 0x00418937U,
	Thresh99Percent      = 0xfd70a3d6U,

	// those numbers are quite similar, so we xor each result with a random number
	XorBrickToCracked    = 0x58e6852aU,
	XorBrickToMoss       = 0x2bda4cf3U,
	XorBrickToPlain      = 0xac86edbdU,
	XorPlainToCobble     = 0x9edc574eU,
	XorCobbleToMossy     = 0x5fae7f06U
	;

	//debug stderr.write(".");

	foreach (y_ ; 0..256) foreach (ubyte z ; 0..16) foreach (ubyte x ; 0..16) {
		ubyte y = cast(ubyte) y_;
		auto blk = c[x, y, z];

		uint draw = Chunk.rng.front;

		// degrade stone
		if (blk.id == BlockType.Cobblestone && (draw ^ XorCobbleToMossy) < ThreshCobbleToMossy) {
			c[x, y, z] = BlockType.Moss_Stone;
		}
		else if (blk.id == BlockType.Stone && (draw ^ XorPlainToCobble) < ThreshPlainToCobble) {
			c[x, y, z] = BlockType.Cobblestone;
		}
		else if (blk.id == BlockType.Stone_Bricks && (draw ^ XorBrickToPlain) < ThreshBrickToPlain) {
			c[x, y, z] = BlockType.Stone;
		}

		// remove light sources
		else if (blk.id == BlockType.Torch && draw < Thresh99Percent) {
			c[x, y, z] = BlockType.Air;
		}
		else if (blk.id == BlockType.Jack_o_Lantern) {
			c[x, y, z] = BlockIDAndData(BlockType.Pumpkin, blk.data);
		}

		else if (y < 255 && blk.id == BlockType.Grass_Block && c[x, y+1, z].id == BlockType.Air) {
			if (draw < ThreshRose) {
				c[x, cast(ubyte) (y+1u), z] = BlockType.Rose;
			}
			else if (draw < (ThreshRose + ThreshDandelion)) {
				c[x, cast(ubyte) (y+1u), z] = BlockType.Dandelion;
			}
			else {
				c[x, cast(ubyte) (y+1u), z] = BlockIDAndData(BlockType.Grass, cast(BlockData) 1u);
			}
		}

		Chunk.rng.popFront();
	}
	c.modified = true;

}

void cityscape(Chunk c)
{
	auto leftEdge = c[0, 69, 15];
	foreach (ref blk ; c.blocks[]) {
		if (blk) blk = 1;
	}
	c[0, 69, 15] = leftEdge;
	c[7, 69, 7] = BlockType.Jack_o_Lantern;


	Chunk eastChunk = getChunkAt(1, 0);
	if (eastChunk) {
		c[15, 69, 15] = BlockIDAndData(BlockType.Glowstone, cast(BlockData) 0u);
		eastChunk[0, 69, 15] = BlockIDAndData(BlockType.Soul_Sand, cast(BlockData) 0u);
		eastChunk.modified = true;
	}
	else {
		c[15, 69, 15] = BlockIDAndData(BlockType.Wool, cast(BlockData) 14u);
	}

	c.modified = true;
}

void dither(Chunk c)
{
	uint count = 0;
	foreach (ref block, ref data ; lockstep(c.blocks[], c.blockData[])) {
		if (((count >> 8) ^ (count >> 4) ^ count) & 1) {
			block = 0;
			data = 0;
		}
		++count;
	}
	c.modified = true;
}

/// Flip an entire world upside down.
void australia(Chunk c)
{
	void flip(T, uint X, uint Y, uint Z)(ref Chunk.BlockArray!(T, X, Y, Z) ba)
	{
		foreach (z ; 0..Z) foreach (x ; 0..X) foreach (y ; 0..Y/2) {
			uint yrev = Y-1 - y;
			auto t = ba[x, y, z];
			ba[x, y, z] = ba[x, yrev, z];
			ba[x, yrev, z] = t;

			debug(none) {
				if (c.coord == CoordXZ(0, 0) && x == (z - 1)) stderr.writefln("Swapping (%d,%d,%d) and (%d,%d,%d)", x, y, z, x, yrev, z);
			}
		}
	}

	flip!(BlockID, 16, 256, 16)(c.blocks);
	flip!(ubyte, 16, 256, 16)(c.blockData);
	flip!(ubyte, 16, 256, 16)(c.blockLight);

	// apparently minecraft disagrees with this analysis -- TODO: why?
	c.mHeightMap[] = 256u;
	c.skyLight.array[] = 0u;

	c.modified = true;
}

