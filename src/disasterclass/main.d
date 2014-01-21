// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.main;

/// Rough-and-ready command-line interface.

import disasterclass.nbt;
import disasterclass.world;
import disasterclass.chunk;
import disasterclass.region;
import disasterclass.support;
import disasterclass.data;
import disasterclass.versioninfo;
import disasterclass.parallel;

import disasterclass.filters.atlantis;

import std.file;
import std.stdio;
import std.exception;
import std.algorithm;
import std.range;
import std.string;
import std.array : join, joiner, minimallyInitializedArray;
import std.format : formattedRead;
import std.conv;
import std.getopt;
import std.parallelism : totalCPUs;
import std.concurrency : send;

alias ExitCode function(string[]) CmdlineFunc;
immutable CmdlineFunc[string] cmds;
immutable CmdlineFunc[] cmdsWithoutWorld;

static this()
{
	CmdlineFunc[string] cmdstemp;

	// Standard functions
	cmdstemp["countchunks"] = &main_countchunks;
	cmdstemp["stats"      ] = &main_stats;
	cmdstemp["freshen"    ] = &main_freshen;

	// Chunk processors
	cmdstemp["stoneage"   ] = &main_stoneage;
	cmdstemp["dither"     ] = &main_dither;
	cmdstemp["cityscape"  ] = &main_cityscape;
	cmdstemp["australia"  ] = &main_australia;
	cmdstemp["atlantis"   ] = &main_atlantis;
	cmdstemp["frequency"  ] = &main_frequency;

	cmdstemp["querydata"] = &main_querydata;

	debug {
		cmdstemp["pokeregion"] = &main_pokeregion;
	}
	cmdstemp.rehash();
	cmds = assumeUnique(cmdstemp);

	cmdsWithoutWorld = [&main_querydata];
}

/// Each cmdline function returns one of these. This code is displayed to the user, as well as forming $(I Disasterclass)'s return code.
enum ExitCode : int
{
	Success = 0,
	BadCmdlineArgs,
	BadWorldPath,
	CorruptWorld,


	UserError = 126,
	InternalError = 127
}

class Options_t
{
	Dimension dimension = Dimension.Overworld;
	string worldPath;
	uint[string] cacheSizes, metrics;
	bool[string] itinerary;
	uint nThreads;
	uint rngSeed;

	void parseDimensionString(string option, string value)
	{
		debug stderr.writefln(q{Parsing "%s" into a dimension}, value);
		try {
			auto dNumber = to!byte(value);
			enforce(dNumber >= Dimension.Nether && dNumber <= Dimension.End, "Invalid dimension number %d".format(dNumber));
			dimension = cast(Dimension) dNumber;
			return;
		}
		catch (ConvException) { /* it wasn't a numeric input. okay, ignore. */ }

		switch (value.toLower()) {
			case "overworld": dimension = Dimension.Overworld; return;
			case "nether":    dimension = Dimension.Nether;    return;
			case "end":       dimension = Dimension.End;       return;
			default: throw new Exception("Invalid dimension: " ~ value);
		}
	}
}

Options_t Options;
private World mainWorld;

/// Entry point for the $(I Disasterclass) command-line app. Dispatches to a command.
int main(string[] args)
{
	Options = new Options_t;

	ExitCode r = ExitCode.InternalError;
	scope(exit) {
		writeln();
		if (r != ExitCode.Success) {
			string reason = [
			ExitCode.BadCmdlineArgs: "bad command line arguments",
			ExitCode.BadWorldPath: "invalid path to Minecraft world",
			ExitCode.CorruptWorld: "corrupted Minecraft world",
			ExitCode.UserError: "user error",
			ExitCode.InternalError: "internal error"
			].get(r, "unknown reason");
			writeln("Quitting Disasterclass due to ", reason);
		}
		else writeln("Success");
	}

	{
		scope string toPrint = "Disasterclass " ~ Version.String ~ ", " ~ Version.Platform;
		scope char[] toPrint2 = new char[toPrint.length];
		toPrint2[] = '=';
		writeln(toPrint, '\n', toPrint2, '\n');
	}

	if (args.length < 2) {
		stderr.write( format("No command specified. Try one of these: %s\n\n", join(cmds.byKey(), ", ")) );

		r = ExitCode.BadCmdlineArgs;
		return r;
	}

	string cmd = args[1];
	args = args[1..$];

	auto matchingFunc = cmd in cmds;
	if (!matchingFunc) {
		writefln("Command '%s' not recognised. Try one of these: %s\n\n", cmd, join(cmds.byKey(), ", "));
		r = ExitCode.BadCmdlineArgs;
		return r;
	}


	try {
		//debug stderr.writefln("Args before: %s", args);
		Options.nThreads = totalCPUs;
		getopt(args,
			std.getopt.config.caseInsensitive,
			std.getopt.config.passThrough,
			"world", &Options.worldPath,
			"dimension", &Options.parseDimensionString,
			"cachesize", &Options.cacheSizes,
			"threads", &Options.nThreads,
			"rng-seed", &Options.rngSeed,
			"itinerary", &Options.itinerary,
			"metrics", &Options.metrics
			);
		//debug stderr.writefln("Args after: %s", args);

		try {
			if (cmdsWithoutWorld.countUntil(*matchingFunc) < 0) mainWorld = new World(Options.worldPath);
		}
		catch (FileException e) {
			stderr.writefln("Couldn't open world %s: %s", Options.worldPath, e.msg);
			return ExitCode.BadWorldPath;
		}

		//writefln("Will use up to %d %s.", Options.nThreads, Options.nThreads == 1 ? "thread" : "threads");

		r = (*matchingFunc)(args);
		if (Options.itinerary.get("relight", false)) {
			relightWorld();
		}
	}
	catch (Exception e)
	{
		debug {
			throw e;
		}
		else {
			stderr.writefln("Exception %s found: %s", e.classinfo.name, e);
			return ExitCode.UserError;
		}
	}
	catch (Error e)
	{
		debug {
			throw e;
		}
		else {
			stderr.writefln("Fatal error %s found: %s", e.classinfo.name, e);
			return ExitCode.InternalError;
		}
	}

	return r;
}

/++
	Counts the chunks in a world's overworld.

	Yep. That's all it does.

	Params:
		arg0 = Path to Minecraft world.
+/
ExitCode main_countchunks(string[] args)
{
	writefln("World: %s (%d chunks)", mainWorld.name, mainWorld.numberOfChunks());

	return ExitCode.Success;
}

/++
	Tallies up the number of blocks in a Minecraft world, and lists the results on stdout.

	Params:
		arg0 = Path to Minecraft world.
		arg1 = Dimension to check - $(I overworld), $(I nether) or $(I end).
+/
ExitCode main_stats(string[] args)
{
	Dimension dimension = Options.dimension;

	writefln("Examining the %s dimension of \"%s\" at %s.", dimension, mainWorld.name, Options.worldPath);
	writefln("Region contains %d chunks total.", mainWorld.numberOfChunks(dimension));
	writefln("Dimension extents: %s", mainWorld.extents(dimension));


	struct BlockCounts { immutable(ulong)[] blockCounts; }

	// stats contexts
	class StatsMTContext : MTContext
	{
		// this type lets us rearrange the block ids, to sort them later
		alias Tuple!(BlockID, "blockID", ulong, "count") Counts_t;

		this()
		{
			mCounts = new Counts_t[NBlockTypes];
			//mCounts = minimallyInitializedArray!(Counts_t[])(NBlockTypes);
			foreach (BlockID i, ref c ; mCounts) {
				c.blockID = i;
				c.count = 0UL;
			}
		}

		override void processMessage(Variant v)
		{
			debug stderr.writefln("StatsMTContext found message %s", v.type);
			BlockCounts* msg = v.peek!(BlockCounts);
			assert(msg);
			//mCounts[] += msg.blockCounts[];
			foreach (src, ref dst ; lockstep(msg.blockCounts[], mCounts)) {
				dst.count += src;
			}
		}

		private Counts_t[] mCounts;
	}

	class StatsContext : WTContext
	{
		ulong[NBlockTypes] blocks;

		override void processChunk(Chunk c, ubyte pass)
		{
			foreach (BlockID blk, BlockData data ; c) {
				++blocks[blk];
			}
		}

		override void cleanup()
		{
			manager.send(BlockCounts( blocks[].assumeUnique() ));
		}
	}

	scope ct = new StatsMTContext;
	auto result = runParallelTask(mainWorld, dimension, typeid(StatsContext), ct, Options.nThreads);

	immutable(StatsMTContext.Counts_t)[] counts = ct.mCounts[].sort!"a.count > b.count"().release().assumeUnique();

	writeln("Stats results:");
	bool foundSomeBlocks = false;
	ulong totalBlocks = reduce!"a + b.count"(0UL, counts); // don't include air, it skews the results

	foreach (pair ; counts) {

		if (pair.count == 0) continue;
		foundSomeBlocks = true;

		// clearer formatting
		string factor = null;
		if (pair.blockID != 0) {
			auto percentage = cast(double) pair.count / totalBlocks * 100;
			//debug stderr.writefln("%d / %d * 100 = %.2f", pair.count, totalBlocks, percentage);
			factor = " (%.04f%% of remaining blocks)".format(percentage);
		}
		writefln("%s (%d): %d%s", blockOrItemName(cast(BlockID) pair.blockID), pair.blockID, pair.count, factor);
		//debug stderr.writefln("totalBlocks: %d - %d = %d", totalBlocks, pair.count, totalBlocks - pair.count);
		totalBlocks -= pair.count; // update percentage to discount higher-count blocks that came before
	}
	writeln();
	if (result.skipped) {
		writefln("%d %s skipped.", result.skipped, result.skipped == 1 ? "chunk" : "chunks");
	} else {
		writeln("No chunks skipped.");
	} 
	if (foundSomeBlocks) writeln("\nPercentages do not include air blocks, since they skew the other numbers too much.");
	else writefln("No blocks found in \"%s\" > %s", mainWorld.name, dimension);

	return ExitCode.Success;	
}

ExitCode main_frequency(string[] args)
{
	BlockID[] blocksToTrack;

	void parseBlockString(string _, string s)
	{
		with (BlockType) switch (s) {
			case "ores":
			blocksToTrack = [Coal_Ore, Iron_Ore, Gold_Ore, Diamond_Ore, Lapis_Lazuli_Ore, Emerald_Ore, Redstone_Ore];
			return;
		
			case "redstone":
			blocksToTrack = [Redstone_Wire, Redstone_Torch_inactive, Redstone_Torch_active, Redstone_Repeater_inactive, Redstone_Repeater_active, Redstone_Lamp_inactive, Redstone_Lamp_active, Block_of_Redstone, Weighted_Pressure_Plate_Light, Weighted_Pressure_Plate_Heavy, Dispenser, Dropper, Powered_Rail, Detector_Rail, Piston, Sticky_Piston, Stone_Pressure_Plate, Wooden_Pressure_Plate, Stone_Button, Wooden_Button, Lever, Trapped_Chest, Tripwire, Tripwire_Hook, Daylight_Sensor, Hopper, Activator_Rail];
			return;

			default:
			blocksToTrack = s.splitter(',').map!(to!BlockID)().array();
			return;
		}
		assert(0);
	}

	getopt(args, std.getopt.config.caseInsensitive, "frequency-blocks", &parseBlockString);

	struct FrequencyResultMsg
	{
		immutable(ulong)[] counts;
		BlockID blockType;
	}

	struct FrequencyTrackingListMsg { immutable(BlockID)[] list; }

	class FrequencyContext : WTContext
	{

		override void processChunk(Chunk c, ubyte pass)
		{
			//debug stderr.writefln("[freq] Processing chunk %s", c.coord);
			foreach (blockType, counts ; mTracker) {
				const(BlockID)[] chunkBlocks = c.blocks[];
				foreach (y ; 0..Chunk.Height) {
					foreach (z ; 0..Chunk.Length) foreach (x ; 0..Chunk.Length) {
						if (chunkBlocks.front == blockType) ++counts.front;
						chunkBlocks.popFront();
					}
					//debug stderr.writefln("[freq] %s y=%d count=%d", c.coord, y, counts.front);
					counts.popFront(); // reduce output slice
				}
			}
		}

		override void processMessage(Variant v)
		{
			debug stderr.writefln("[WT%d] Trace: FrequencyContext.processMessage (%s)", this.threadId, v.type());
			if (v.peek!FrequencyTrackingListMsg()) {
				auto msg = v.get!FrequencyTrackingListMsg();
				foreach (blockType ; msg.list) {
					debug stderr.writefln("[WT%d]: initing search for block type %d", this.threadId, blockType);
					mTracker[blockType] = new ulong[Chunk.Height];
				}
				mTracker.rehash();
			}
		}

		override void cleanup()
		{
			foreach (blockType, ref counts ; mTracker) {
				manager.send(FrequencyResultMsg(counts.assumeUnique(), blockType));
				counts = null;
			}
		}

	private:
		ulong[][BlockID] mTracker;
		immutable(BlockID)[] sBlocksToTrack;
	}

	class FrequencyMTContext : MTContext
	{
		this(immutable(BlockID)[] blockTypesToTrack)
		{
			mBlockTypesToTrack = blockTypesToTrack;

			writefln("Tracking frequency of these blocks: %s", blockTypesToTrack.map!(blockOrItemName)().joiner(", "));

			foreach (blockType ; mBlockTypesToTrack) {
				mGlobalTracker[blockType] = new ulong[Chunk.Height + 1];
				// index Chunk.Height stores total number blocks of this type found at all (i.e. sum(mGlobalTracker[0..Chunk.Height]) == mGlobalTracker[Chunk.Height])
			}
		}

		override void begin()
		{
			//debug stderr.writefln("[MT] Broadcasting FrequencyTrackingListMsg");
			broadcast(FrequencyTrackingListMsg(mBlockTypesToTrack));
		}

		override void processMessage(Variant v)
		{
			auto msg = v.peek!FrequencyResultMsg();
			if (msg is null) return;

			assert(msg.blockType in mGlobalTracker);

			auto globalCounts = mGlobalTracker[msg.blockType];
			foreach (threadCount, ref globalCount ; lockstep(msg.counts, globalCounts)) {
				globalCount += threadCount;
				globalCounts[Chunk.Height] += threadCount;
			}
			//debug stderr.writefln("Found %d blocks total of block id %d", globalCounts[Chunk.Height], msg.blockType);
		}

	private:
		ulong[][BlockID] mGlobalTracker;
		immutable(BlockID)[] mBlockTypesToTrack;
	}

	scope ctx = new FrequencyMTContext(blocksToTrack.idup);
	auto result = runParallelTask(mainWorld, Options.dimension, typeid(FrequencyContext), ctx);

	writeln("Frequency results:");
	foreach (blockType, counts ; ctx.mGlobalTracker) {
		writefln("%s (block ID %d)", blockOrItemName(blockType), blockType);
		auto total = counts[Chunk.Height];
		//debug stderr.writefln("Index 256 total: %d. Reduce-sum total: %d.", counts[Chunk.Height], reduce!"a + b"(0UL, counts[0 .. Chunk.Height]));
		if (total == 0) {
			writeln(" (no blocks found)");
			continue;
		}
		foreach (y, freq ; zip(iota(Chunk.Height), counts[0 .. $-1]).retro().filter!"a[1] != 0"()) {
			writefln("%4d: %d (%.4f%%)", y, freq, cast(real) (freq * 100) / total);
		}
	}

	return ExitCode.Success;
}

/++
	Essentially, a command-line interface to $(D_CODE Region.findGapToWriteChunk). Not a lot of use if that function stays bug-free.
+/
deprecated debug ExitCode main_pokeregion(string[] args)
{
	writeln(
		"<pokeregion> For testing purposes only. Doesn't support Nether or End.\n"
		"\n"
		"Type three numbers (chunk X, chunk Z, comp'd chunk size in 4KiB sectors) and\n"
		"Disasterclass will tell you where it'd save it.\n"
		"Type q to quit."
		);

	int x, z; uint size;

	Lmain: while (true) {
		// parse cmdline

		stderr.write("> ");
		auto line = stdin.readln().stripLeft();
		if (!line.length) continue Lmain;
		if (line[$-1] == '\n') line = line[0..$-1];

		if (line == "q") break Lmain;

		try {
			if (line.formattedRead("%d", &x) == 0) goto LparseError;
			line = line.stripLeft();
			if (line.formattedRead("%d", &z) == 0) goto LparseError;
			line = line.stripLeft();
			if (line.formattedRead("%d", &size) == 0) goto LparseError;
		}
		catch (ConvException) {
			goto LparseError;
		}

		stderr.writef("%d, %d (%d sr): ", x, z, size);

		auto regionCoord = CoordXZ(x / 32, z / 32), subCoord = CoordXZ(x & 31, z & 31);

		Region region = mainWorld.mAllRegionsOverworld.get(regionCoord, null);
		if (region is null) {
			stderr.writefln("No region exists for %s - would write at 0x2000.", CoordXZ(x,z));
			continue Lmain;
		}

		auto foundRange = region.findGapToWriteChunk(subCoord, size * 4096);

		stderr.writefln("Found %s (offsets %x to %x in region %s)", foundRange, foundRange.front * 4096, foundRange.end * 4096, region.id);
		continue Lmain;

		LparseError:
		stderr.writefln("Parse error. Try again.");
		continue Lmain;	
	}

	return ExitCode.Success;
}

/++
	Interface to $(D_CODE Chunk.basicStoneAge). Transforms stone blocks in all chunks according to its simplistic rules.
+/
ExitCode main_stoneage(string[] args)
{
	// a VERY BASIC stoneage interface
	import disasterclass.filters.stoneage;

	writefln("Seeding StoneAge twister with %d.", Options.rngSeed);
	Chunk.rngSeed = Options.rngSeed;

	//Chunk c = mainWorld.byRegion(Dimension.Overworld).front.byChunk.front;
	//c.basicStoneAge();

	runParallelTask(mainWorld, Dimension.Overworld, typeid(StoneAgeContext), null, Options.nThreads);

	mainWorld.updateTimestamp();
	mainWorld.saveLevelDat("[dc13:stoneage]");

	return ExitCode.Success;
}

/++
	Forcibly re-commits all chunks back to the region, without changing their game data.
+/
ExitCode main_freshen(string[] args)
{

	foreach (region ; mainWorld.byRegion(Dimension.Overworld)) {
		stdout.writefln("Region %s (%d chunks)...", region.id, region.numberOfChunks); stdout.flush();
		foreach (chunkCoord ; region.byChunk) {
			auto chunkNBT = region.decompressChunk(chunkCoord.regionSubCoord);
			auto chunk = new Chunk(chunkCoord, Dimension.Overworld, chunkNBT);

			region.writeChunk(chunk.coord, chunk.flatten());

			destroy(chunk);
		}
	}

	return ExitCode.Success;
}

/++
	Checkerboards the world. Was invented to reduce compression efficiency and track down a very stealthy region bug.
+/
ExitCode main_dither(string[] args)
{
	class DitherContext : WTContext
	{
		override void processChunk(Chunk c, ubyte pass)
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
	}

	runParallelTask(mainWorld, Dimension.Overworld, typeid(DitherContext), null, Options.nThreads);

	mainWorld.updateTimestamp();
	mainWorld.saveLevelDat("[dc13:dither]");

	return ExitCode.Success;
}

/***

Turns a world into a bland cityscape. Converts $(I all) non-air blocks (including bedrock) into plain stone.

It also adds jack o'lanterns, glowstone and red wool in various places at Y=69, as an old test for finding local chunk neighbours.

*/
ExitCode main_cityscape(string[] args)
{
	class CityscapeContext : WTContext
	{
		override void processChunk(Chunk c, ubyte pass)
		{
			auto leftEdge = c[0, 69, 15];
			foreach (ref blk ; c.blocks[]) {
				if (blk) blk = 1;
			}
			c[0, 69, 15] = leftEdge;
			c[7, 69, 7] = BlockType.Jack_o_Lantern;


			Chunk eastChunk = c.neighbourAt(1, 0);
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
	}

	runParallelTask(mainWorld, Dimension.Overworld, typeid(CityscapeContext), null, Options.nThreads);

	mainWorld.updateTimestamp();
	mainWorld.saveLevelDat("[dc13:cityscape]");

	return ExitCode.Success;
}

ExitCode main_australia(string[] args)
{
	class AustraliaContext : WTContext
	{
		override void processChunk(Chunk c, ubyte pass)
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

			// apparently minecraft disagrees with this analysis -- TODO: why? [Could well be because this world type confuses Minecraft]
			c.heightMap[] = 256u;
			c.skyLight.array[] = 0u;

			c.modified = true;
		}
	}

	runParallelTask(mainWorld, Dimension.Overworld, typeid(AustraliaContext), null, Options.nThreads);

	// flip the player's Y position
	auto ynode = mainWorld.levelRootNode["Data"]["Player"]["Pos"][1];
	ynode.doubleValue = 255 - ynode.doubleValue;

	mainWorld.updateTimestamp();
	mainWorld.name = mainWorld.name.dup.reverse.assumeUnique();
	mainWorld.saveLevelDat("[DC: Australia]");

	return ExitCode.Success;
}

ExitCode main_atlantis(string[] args)
{
	enum uint DefaultCeilingGap = 8;	
	Atlantis.ceilingGap = min(Options.metrics.get("atlantis-ceiling-gap", DefaultCeilingGap), ubyte.max);

	runParallelTask(mainWorld, Dimension.Overworld, typeid(Atlantis.Context), null, Options.nThreads);

	mainWorld.updateTimestamp();
	mainWorld.saveLevelDat("[DC: Atlantis]");

	return ExitCode.Success;
}

ExitCode main_querydata(string[] args)
{
	write("Transparent blocks: ");
	foreach (value ; Blocks.byValue().filter!((b) => (b.flags & Flags.Transparent) != 0)().map!"a.name[]"().joiner(", ")) {
		write(value);
	}
	writeln("\n");

	return ExitCode.Success;
}

void relightWorld()
{
	// relight the world
	class RelightWTContext : WTContext
	{
		override void processChunk(Chunk c, ubyte pass)
		{
			c.relight2();
		}
	}

	runParallelTask(mainWorld, Options.dimension, typeid(RelightWTContext), null, Options.nThreads);
}
