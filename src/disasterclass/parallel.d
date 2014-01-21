// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.parallel;

/// Multicore thread dispatcher. Offers an interface to run per-chunk processes in parallel.

import disasterclass.world;
import disasterclass.support;
import disasterclass.chunk;
import disasterclass.nbt : isValidNBT;

import std.concurrency;
public import std.parallelism : totalCPUs;
import std.typecons;
import std.exception : assumeUnique;
import std.algorithm;
import std.range;
import std.stdio;
import std.conv;

// for other modules that subclass [MW]TContext
public import std.concurrency : Tid;
public import std.variant : Variant;

package class MTContext
{
protected:
	/// Called when all worker threads have been set up and able to receive custom messages.
	void begin() { }

	/// Let subclasses deal with other message types.
	void processMessage(Variant v)
	{
		throw new Exception("Manager thread received unknown message: " ~ v.type().toString());
	}

	/// Called when worker threads are finished.
	void cleanup() { }

	final void broadcast(Args...)(Args a)
	{
		foreach (tid ; mWorkerTids) {
			if (tid != Tid.init) tid.send(a);
		}
	}

	// info
	@property World world() { return mWorld; }
	@property Dimension dimension() { return mDimension; }

private:
	Tid[] mWorkerTids;
	World mWorld;
	Dimension mDimension;
}

package class WTContext
{
protected:
	/// Per-thread setup.
	void begin() { }

	/// Called whenever a chunk is created in local memory. Do $(B not) rely on $(D_KEYWORD chunkNeighbours) to contain meaningful data at this point.
	void prepareChunk(Chunk, ubyte) { }

	/// Do task-specific processing by chunk.
	void processChunk(Chunk, ubyte) { }

	/// Process any additional messages.
	void processMessage(Variant v)
	{
		writefln("Worker thread %d received unknown message: %s", threadId, v);
	}

	void cleanup() { }

	// info about the current parallel context
	@property ubyte threadId()
	{
		assert(thisWT);
		return thisWT.workerThreadId;
	}

	@property Tid manager()
	{
		assert(thisWT);
		return thisWT.parentTid;
	}
}


// MT side

Tuple!(ulong, "processed", ulong, "skipped") runParallelTask
(World world, Dimension dimension, ClassInfo wtContextInfo, MTContext ctx = null, uint nThreads = totalCPUs)
{
	Extents worldExtent = world.chunkExtents(dimension);

	nThreads = max(1, min(nThreads, 127));

	if (ctx is null) ctx = new MTContext;

	ctx.mWorld = world;
	ctx.mDimension = dimension;

	debug(dc13Threads3) {
		stderr.writefln("World %s: %d chunks, size %s", world.name, world.numberOfChunks(dimension), worldExtent);
	}

	//
	// find the number of sections we should split the world into
	//

	uint nSplits = max(nThreads, 1); // in most cases, this is true
	/*
		There are certain restrictions on splitting the world:
		• Only split down vertical lines. No horizontal split boundaries.
		• The following must hold true:
			(let n = neighbour radius. let d = 2n + 1)
			• world width >= d
			• number of rationing strips <= floor(world width / d)
	*/
	enum uint NeighbourDiameter = 2 * NeighbourRadius + 1,
	MinWorldWidth = NeighbourRadius * 4;
	if (worldExtent.width < MinWorldWidth + 1) {
		// world is too small to split
		nSplits = 1;
		throw new Exception("World too small to split (must be at least %d chunks wide) -- currently cannot be processed with Disasterclass".format(MinWorldWidth));
	}
	else {
		nSplits = min(
			nSplits,
			worldExtent.width / NeighbourDiameter, // allowed to round down
			200 // hackish, i know
			); 
	}

	//
	// Now find pass1 and pass2 focus and neighbour extents
	//

	// find latitude boundaries between chunks (includes west-most and east-most points) -- we can make all pass rations from this
	auto boundaries = iota(nSplits + 1)
	.map!((s) => s / cast(real) (nSplits) * worldExtent.width)()
	.map!((a) => cast(int) (a) + worldExtent.west)()
	.array();
	debug(dc13Threads3) stderr.writefln("[MT] Boundaries: %s", boundaries);
	assert(boundaries.length == nSplits + 1);

	// convert boundaries into pass1 Rations
	auto pass1Rations = iota(nSplits)
	.map!((i) => Extents(boundaries[i], boundaries[i+1], worldExtent.north, worldExtent.south))().array();
	debug(dc13Threads3) stderr.writefln("[MT] Pass 1 Rations: %s", pass1Rations);
	auto pass1FocusRations = pass1Rations.dup;

	// shrink original Rations west/east to make focus Rations
	foreach (ref ex ; pass1FocusRations[1..$]) ex.west += NeighbourRadius;
	foreach (ref ex ; pass1FocusRations[0..($-1)]) ex.east -= NeighbourRadius;
	debug(dc13Threads3) stderr.writefln("[MT] Pass 1 Focus Rations: %s", pass1FocusRations);

	// pass2 rations just extend out from inner boundaries
	auto pass2FocusRations = boundaries[1..($-1)]
	.map!((b) => Extents(b - NeighbourRadius, b + NeighbourRadius, worldExtent.north, worldExtent.south))().array();
	auto pass2Rations = pass2FocusRations.dup;
	foreach (ref ex ; pass2Rations) {
		ex.west -= NeighbourRadius;
		ex.east += NeighbourRadius;
	}
	debug(dc13Threads3) stderr.writefln("[MT] Pass 2 Focus Rations: %s", pass2FocusRations);

	// array length sanity checks
	assert(pass1Rations.length == pass1FocusRations.length);
	assert(pass2Rations.length == pass2FocusRations.length);
	assert(pass1Rations.length == pass2Rations.length + 1);

	class RationAgent
	{
		// permanent on full init-ing
		Extents ration, focus;

		// mutated upon workload change
		Tid tid;
		ubyte pass;
		ubyte threadId = ubyte.max;

		// mutated during mainloop
		bool wantsAnotherChunk = false;
		Extents.Range areaRange;

		this(Extents ration_, Extents focus_, ubyte pass_)
		{
			ration = ration_; focus = focus_; pass = pass_;
			areaRange = ration[];
		}

		final void init()
		{
			assert(tid != Tid.init);
			tid.send(RationsInfoMsg(ration, focus, pass));
			//wantsAnotherChunk = true;
		}

		//auto _initRange()
		//{
		//	return ration[].filter!(c => world.hasChunkAt(c, dimension))();
		//}

		@property final bool active()
		{
			return pass > 0;
		}

		invariant() {
			assert(pass == 1 || pass == 2);
		}
	}

	final class RationAgentPass2 : RationAgent
	{
		// Dependencies. References to the two pass1 rations that *must* be completed before this pass2 ration can begin.
		RationAgent depWest, depEast;

		this(Extents ration_, Extents focus_, ubyte pass_)
		{
			super(ration_, focus_, pass_);
		}

		invariant() {
			assert((depWest is null) == (depEast is null)); // 0 or 2 null values -- nothing else
			assert((depWest is null && depEast is null) || (depWest != depEast)); // they shouldn't equal each other either
			assert(pass == 2);
		}
	}

	//
	// Create arrays, agents and ranges we'll need for the meat of this func
	//
	auto
	pass1Agents  = new RationAgent[pass1Rations.length],
	pass2Agents  = new RationAgentPass2[pass2Rations.length],
	activeAgents = new RationAgent[nThreads],
	pass1CompletedAgents = pass1Agents.dup;


	foreach (ref agent, ration, focus ; lockstep(pass1Agents, pass1Rations, pass1FocusRations)) {
		agent = new RationAgent(ration, focus, 1);
	}

	foreach (i, ref agent, ration, focus ; lockstep(pass2Agents, pass2Rations, pass2FocusRations)) {
		agent = new RationAgentPass2(ration, focus, 2);
		agent.depWest = pass1Agents[i]; agent.depEast = pass1Agents[i+1];
	}

	Tid[] workerThreads = new Tid[nThreads];
	foreach (i, ref t ; workerThreads) {
		debug(dc13Threads3) stderr.writefln("[MT] Spawning worker thread %d", i);
		t = spawn(&WT.launch, thisTid, cast(immutable ClassInfo)(wtContextInfo), dimension, cast(ubyte) i);
		setMaxMailboxSize(t, 12/* a guess, but should be enough */, OnCrowding.block);
	}
	if (ctx) ctx.mWorkerTids = workerThreads; // let MTContext see these, for MTContext.broadcast

	// we'll need these

	//bool done = false;
	ulong cycleCount = 0, chunksProcessed = 0, chunksSkipped = 0;

	setMaxMailboxSize(thisTid, 12/* hackish */, OnCrowding.block);

	if (ctx) ctx.begin();

	for (; !(pass1Agents.empty && pass2Agents.empty && activeAgents.all!"a is null"()); ++cycleCount) {

		// replace null workloads with new ones, if we can
		//debug(dc13Threads3) stderr.writefln("[MT] Trace: LNewTask");
		LNewTask: foreach (i, ref agent ; activeAgents) {
			if (agent !is null) continue;

			debug(dc13Threads3) stderr.writefln("[WT] WT%d agent gap potentials: %d pass1, %d pass2", i, count!"a !is null"(pass1Agents), count!"a !is null"(pass2Agents));

			if (pass2Agents.empty) goto Lpass1;
			// try and pull the latest from pass2
			RationAgentPass2 p2f = pass2Agents.front;
			auto
			depWestLoc = pass1CompletedAgents.countUntil!"a is b"(p2f.depWest),
			depEastLoc = pass1CompletedAgents.countUntil!"a is b"(p2f.depEast);
			// we should only continue if both W/E pass1 deps are proven completed
			if (depWestLoc == -1 || depEastLoc == -1) goto Lpass1;

			debug(dc13Threads3) stderr.writefln("[MT] Pulling front pass2 agent into active pool: WT%d ration = %s", i, p2f.ration);
			agent = p2f;
			agent.threadId = cast(ubyte) i;
			agent.tid = workerThreads[i];
			agent.init();
			pass2Agents.popFront();
			debug(dc13Threads3) stderr.writefln("[MT] Found pass2's dependents at positions %d and %d; removing from pass1CompletedAgents", depWestLoc, depEastLoc);
			pass1CompletedAgents[depWestLoc] = null;
			pass1CompletedAgents[depEastLoc] = null;
			continue LNewTask;

			Lpass1:
			if (pass1Agents.empty) continue LNewTask;
			agent = pass1Agents.front;
			debug(dc13Threads3) stderr.writefln("[MT] Pulling front pass1 agent into active pool: WT%d ration = %s", i, agent.ration);
			agent.tid = workerThreads[i];
			agent.threadId = cast(ubyte) i;
			agent.init();
			pass1Agents.popFront();
		}

		// send chunks to any WT that's requesting them
		//debug(dc13Threads3) stderr.writefln("[MT] Trace: LoopActiveAgents");
		LoopActiveAgents: foreach (agent ; activeAgents.filter!(a => a !is null && a.wantsAnotherChunk)()) {
			immutable(ubyte)[] chunkStream = null;
			debug(dc13Threads3) stderr.writefln("[MT] WT%d wants another chunk", agent.threadId);
			// emulate std.algorithm.filter in looping on missing chunks
			while (!agent.areaRange.empty) {
				CoordXZ chunkCoord = agent.areaRange.front;
				chunkStream = ctx.world.loadChunkNBT(chunkCoord, dimension).assumeUnique();
				if (chunkStream is null) {
					agent.areaRange.popFront();
					continue;
				}

				debug(dc13Threads3) stderr.writefln("[MT] Sending chunk %s to WT%d", chunkCoord, agent.threadId);
				agent.tid.send(ChunkCheckoutMsg(chunkCoord, chunkStream));
				agent.wantsAnotherChunk = false;
				agent.areaRange.popFront();
				continue LoopActiveAgents;
			}

			// what if the area range is now empty?
			debug(dc13Threads3) stderr.writefln("[MT] Telling WT%d its stream is done", agent.threadId);
			agent.tid.send(ChunkStreamDoneMsg());
			agent.wantsAnotherChunk = false;
		}

		// receive any messages from WTs
		//debug(dc13Threads3) stderr.writefln("[MT] Trace: receive");
		receive(
			(ChunkRequestMsg _) {
				activeAgents[_.workerThreadId].wantsAnotherChunk = true;
			},

			(ChunkCheckinMsg _) {
				debug (dc13Threads3) stderr.writefln("[MT] Chunk %s returned from WT%d (modified: %s)", _.coord, _.workerThreadId, _.stream !is null);
				if (_.stream) ctx.world.saveChunkNBT(_.coord, _.stream, dimension);
				auto agent = activeAgents[_.workerThreadId];
				agent.wantsAnotherChunk = _.requestNextChunk;
			},

			(WTWorkloadCompleteMsg _) {
				debug(dc13Threads3) stderr.writefln("[MT] WT%d has done current workload; processed %d, skipped %d", _.workerThreadId, _.chunksProcessed, _.chunksSkipped);
				auto agent = activeAgents[_.workerThreadId];
				chunksProcessed += _.chunksProcessed;
				chunksSkipped   += _.chunksSkipped;

				// if pass 1, move this agent to the holding pen for its pass2 children to track
				if (agent.pass == 1) pass1CompletedAgents.find!"a is null"().front = agent;
				activeAgents[_.workerThreadId] = null;
				debug(dc13Threads3) stderr.writefln("[MT] WT%d agent removed from activeAgents; leaves %d gap(s)", _.workerThreadId, activeAgents.count!"a is null"());
			},

			(shared(Throwable) e) {
				debug stderr.writefln("Found %s in worker thread -- throwing...", typeid(e));
				throw e;
			},

			(Variant v) {
				if (ctx) ctx.processMessage(v);
			}
		);

		debug(dc13Threads3) stderr.writefln("[MT] Remaining in pass1CompletedAgents: %s", zip(iota(pass1CompletedAgents.length), pass1CompletedAgents).filter!(p => p[1] !is null)().map!(p => "%s at pos %d".format(p[1].areaRange.extents, p[0]))().join(", "));

		// that's the loop done
	}

	//assert(chain(pass1Agents, cast(RationAgent[]) pass2Agents, activeAgents, pass1CompletedAgents).all!"a is null"(), "There are stray agents");
	assert(pass1Agents.all!"a is null"(), "There are stray agents in pass1Agents");
	assert((cast(RationAgent[]) pass2Agents).all!"a is null"(), "There are stray agents in pass2Agents");
	assert(activeAgents.all!"a is null"(), "There are stray agents in activeAgents");
	assert(pass1CompletedAgents.all!"a is null"(), "There are stray agents in pass1CompletedAgents");


	if (ctx) ctx.cleanup();

	// let all WTs know they are to end gracefully
	foreach (tid ; workerThreads) tid.send(NoMoreRationsMsg());

	// wait until we know all worker threads are done
	do {
		receive(
			(WTDoneMsg _) {
				workerThreads[_.workerThreadId] = Tid.init;
				debug(dc13Threads3) stderr.writefln("[MT] WT%d confirms it's ready to shut down", _.workerThreadId);
			},

			(Variant v) {
				if (ctx) ctx.processMessage(v);
			}
		);
	} while (any!(tid => tid != Tid.init)(workerThreads));

	writefln("Task complete (%d chunks processed, %d skipped)", chunksProcessed, chunksSkipped);
	return typeof(return)(chunksProcessed, chunksSkipped);
}

/// Number of neighbouring chunks available to surround the current chunk. This will eventually be changeable at runtime.
enum ubyte NeighbourRadius = 1;


private {
	// MT → WT
	/// Tells a WT what workload it's about to process.
	struct RationsInfoMsg
	{ Extents ration, focus; ubyte pass; }
	/// Checked-out chunk given to the WT.
	struct ChunkCheckoutMsg
	{ CoordXZ coord; immutable(ubyte)[] stream; }
	/// Tells the WT that no more chunks can/will be sent.
	struct ChunkStreamDoneMsg {}
	/// Tells the WT that it has no more rations, and should terminate.
	struct NoMoreRationsMsg {}

	// WT → MT
	/// Chunk sent to the MT to be saved back into the region.
	struct ChunkCheckinMsg
	{ ubyte workerThreadId; CoordXZ coord; immutable(ubyte)[] stream; bool requestNextChunk; }
	/// Signal that the WT wants another chunk
	struct ChunkRequestMsg
	{ ubyte workerThreadId; }
	/// Signals that the WT has ostensibly finished this workload.
	struct WTWorkloadCompleteMsg
	{ ubyte workerThreadId; ulong chunksProcessed; ulong chunksSkipped; }
	/// Signals that the worker thread has completed all its rations, and the WTContext object has finished its cleanup.
	struct WTDoneMsg
	{ ubyte workerThreadId; }
}


// WT side

private struct WT
{
	enum State
	{
		Inactive,   // waiting in the lobby
		Warming,   // filling LGC, no active chunk
		Active,   // there's an active chunk (LGC may / may not be full)
		Flushing // LGC and AC empty; only LDC to serialize and send back
	}

	// set by arguments from MT
	Tid parentTid; /// Manager Thread Tid.
	Rebindable!(immutable ClassInfo) classInfo; /// The subclass of WTContext to make.
	Dimension dimension; /// Dimension of this world, since the World object is unavailable.
	ubyte workerThreadId; /// Numeric id of the worker thread (replaces WorkerTaskId in version 2).

	// explicitly inited in launch func
	State state;

	// unset until a RationsInfoMsg arrives
	WTContext context; /// Worker Thread agent, managing this filter's ultimate job.
	Extents ration, focus; /// Extents to iterate over.
	size_t leadLagSize; /// In the N–S, E–W linear iteration, how much total bufferage (with thisChunk in the middle) is needed each side to guarantee that a 1-chunk border remains loaded?
	ubyte pass; /// Pass number of this workload (1 or 2)
	debug uint rationsProcessed; /// Track number of rations processed -- 
	bool chunkStreamEmpty = false;

	Tuple!(size_t, "centreIndex", size_t, "deltaIndexShift") neighbourMetrics;

	/*
	outgoingChunk (in shiftChunks only) ← leadingChunks[] ← thisChunk ← laggingChunks[] ← checked-in chunks
	*/

	/*
	These arrays should be circular buffers, but honestly, the inefficiency here is negligible.
	*/
	Chunk[] leadingChunks; // NW of current chunk, already processed
	Chunk thisChunk; // currently processing chunk
	Chunk[] laggingChunks; // SE of current chunk; not processed

	ulong
	cycleCount = 0,      /// Number of loop cycles the worker thread runs
	chunksProcessed = 0, /// Number of chunks successfully processed
	chunksSkipped = 0;   /// Number of chunks reverted due to error

	/// Holding pattern function for worker threads. Dispatches rations as they come in.
	void workerLobby()
	{
		bool done = false;

		try {
			context = cast(WTContext) classInfo.create();

			while (!done) {
				receive(

					(RationsInfoMsg _) {
						debug(dc13Threads3) stderr.writefln("[WT%d] Received pass%d workload: ration %s, focus %s", workerThreadId, _.pass, _.ration, _.focus);
						ration = _.ration;
						focus  = _.focus ;
						pass   = _.pass  ;
						assert(context);

						chunkNeighbours = new Chunk[4 * NeighbourRadius * (NeighbourRadius + 1) + 1];
						neighbourMetrics.centreIndex = 2 * NeighbourRadius * (NeighbourRadius + 1);
						neighbourMetrics.deltaIndexShift = NeighbourRadius * (neighbourMetrics.centreIndex + 1);
						debug(dc13Threads3) stderr.writefln("[WT%d] Neighbour metrics: %s", workerThreadId, neighbourMetrics);

						debug(dc13Threads3) stderr.writefln("[WT%d] Leaving lobby, moving to main.", workerThreadId);
						this.main();

						// neutralise data variables
						ration = Extents.init;
						focus  = Extents.init;
						chunkStreamEmpty = false;
						state = State.Inactive;
						neighbourMetrics.centreIndex = 0; neighbourMetrics.deltaIndexShift = 0;
						leadLagSize = 0; pass = 0;
						cycleCount = 0; chunksProcessed = 0; chunksSkipped = 0;

						assert(leadingChunks.all!"a is null"(), "non-null Chunk refs in leadingChunks");
						assert(laggingChunks.all!"a is null"(), "non-null Chunk refs in laggingChunks");
						assert(thisChunk is null, "thisChunk is not null");
						// fall through to lobby loop
					},
					(NoMoreRationsMsg _) {
						done = true;
					}
				);

			}

			context.cleanup();
			parentTid.send(WTDoneMsg(workerThreadId));
		}

		catch (OwnerTerminated) {
			debug(dc13Threads3) stderr.writefln("OwnedTerminated -- exiting in a calm and orderly manner");
			done = true;
		}

		catch (shared(Throwable) t) {
			debug(dc13Threads3) stderr.writefln("[WT%d] Caught %s in lobby: %s, %s:%d", workerThreadId, typeid(t), t.msg, t.file, t.line);
			parentTid.prioritySend(t);
			done = true;
		}

	}

	/// "Main" function for worker threads.
	void main()
	{
		assert(state == State.Inactive);
		scope(exit) state = State.Inactive;
		debug(dc13Threads3) scope(failure) stderr.writefln("[WT%d] Aborting on cycle count %d in state %s", workerThreadId, cycleCount, state);

		// set lead-lag size
		leadLagSize = (ration.width ) * NeighbourRadius;

		leadingChunks.length = leadLagSize;
		laggingChunks.length = leadLagSize;

		context.begin();

		// state 1: filling LGC as much as possible
		state = State.Warming;
		auto lgcWarmingRange = laggingChunks;

		parentTid.send(ChunkRequestMsg(workerThreadId));

		while (state == State.Warming) {
			debug(dc13Threads3) stderr.writefln("[WT%d] Calling state 1 receive:", workerThreadId);
			receive(
				(ChunkCheckoutMsg _) {
					assert(!lgcWarmingRange.empty);
					assert(lgcWarmingRange.front is null);
					debug(dc13Threads3) stderr.writefln("[WT%d] Got chunk %s", workerThreadId, _.coord);
					try {
						auto newChunk = new Chunk(_.coord, dimension, _.stream);
						context.prepareChunk(newChunk, pass);
						if (thisChunk is null) {
							debug(dc13Threads3) stderr.writefln("[WT%d] Setting thisChunk in state 1", workerThreadId);
							thisChunk = newChunk;
						}
						else {
							lgcWarmingRange.front = newChunk;
							lgcWarmingRange.popFront();
						}

						if (lgcWarmingRange.empty) state = State.Active;
						else parentTid.send(ChunkRequestMsg(workerThreadId));

						debug(dc13Threads3) printChunkLineState();
					}
					catch (Exception e) {
						stderr.writefln("[WT%d] Couldn't create chunk %s: %s", workerThreadId, _.coord, e.msg);
					}

				},

				(ChunkStreamDoneMsg _) {
					debug(dc13Threads3) stderr.writefln("[WT%d] MT agent's chunk stream is done", workerThreadId);
					chunkStreamEmpty = true;
					state = State.Active;
				},

				(OwnerTerminated e) {
					throw e;
				},

				(Variant v) { context.processMessage(v); }
				);

			++cycleCount;
		}

		debug(dc13Threads3) {
			stderr.writefln("[WT%d] Moving to state 2", workerThreadId);
		}

		// state 2: processing chunks
		assert(state == State.Active);
		
		while (state == State.Active) {
			debug(dc13Threads3) {
				scope(failure) printChunkLineState();
				assert(thisChunk !is null);
			}

			if (thisChunk.coord in focus) try {
				scope(failure) thisChunk.modified = false; // if processChunk throws an exception, don't save the chunk back to the region
				//debug(dc13Threads3) stderr.writefln("[WT%d] About to process chunk %s", workerThreadId, thisChunk.coord);
				//debug(dc13Threads3) scope(success) stderr.writefln("[WT%d] Successfully processed chunk %s", workerThreadId, thisChunk.coord);
				context.processChunk(thisChunk, pass);
				++chunksProcessed;
			}
			catch (Exception e) {
				debug(dc13Threads3) stderr.writefln("[WT%d] %s thrown when processing chunk %s: %s", workerThreadId, typeid(e), thisChunk.coord, e.msg);
				++chunksSkipped;
			}

			shiftChunks();

			debug(dc13Threads3) if (!chunkStreamEmpty) stderr.writefln("[WT%d] Chunk stream not empty; will call receive", workerThreadId);
			if (!chunkStreamEmpty) receive(
				// put another chunk in the new trailing null
				(ChunkCheckoutMsg _) {
					debug(dc13Threads3) stderr.writefln("[WT%d] Got chunk %s", workerThreadId, _.coord);
					try {
						assert(laggingChunks[$-1] is null);
						auto newChunk = new Chunk(_.coord, dimension, _.stream);
						context.prepareChunk(newChunk, pass);
						laggingChunks[$-1] = newChunk;
					}
					catch (Exception e) {
						debug(dc13Threads3) stderr.writefln("[WT%d] %s thrown when processing chunk %s: %s", workerThreadId, typeid(e), thisChunk.coord, e.msg);

						++chunksSkipped;
					}
				},

				(ChunkStreamDoneMsg _) {
					chunkStreamEmpty = true;
				}
				);

			if (thisChunk is null) {
				// no more chunks to receive or process
				assert(chunkStreamEmpty);
				state = State.Flushing;
				debug(dc13Threads3) stderr.writefln("[WT%d] State set to %s", workerThreadId, state);
			}

			++cycleCount;
		}

		// state 3: flushing
		assert(state == State.Flushing);
		assert(leadingChunks.find!"a !is null"().all!"a !is null"()); // the only nulls in LDC should all be bunched at the start of the array. No nulls in the stream.
		assert(laggingChunks.all!"a is null"());
		foreach (ref chunk ; leadingChunks.find!"a !is null"()) {
			debug(dc13Threads3) stderr.writefln("[WT%d] Sending back chunk %s from state 3", workerThreadId, chunk.coord);
			returnChunk(chunk);
			chunk = null;
		}

		parentTid.send(WTWorkloadCompleteMsg(workerThreadId, chunksProcessed, chunksSkipped));
	}

	void shiftChunks()
	{
		debug(dc13Threads3) {
			//stderr.writefln("[WT%d] Trace: WT.shiftChunks", workerThreadId);
			scope(success) stderr.writefln("[WT%d] New central chunk: %s", workerThreadId, thisChunk is null ? "(null)" : thisChunk.coord.toString());
		}
		// push outgoing chunk
		auto outgoingChunk = leadingChunks[0];
		if (outgoingChunk) returnChunk(outgoingChunk);
		else if (!chunkStreamEmpty) parentTid.send(ChunkRequestMsg(workerThreadId));

		// shift leading/lagging
		copy( leadingChunks[1..$], leadingChunks[0..($-1)] );
		leadingChunks[$-1] = thisChunk;
		thisChunk = laggingChunks[0];
		copy( laggingChunks[1..$], laggingChunks[0..($-1)] );
		laggingChunks[$-1] = null;

		// create neighbourhood
		if (thisChunk is null) return;

		auto
		neighboursNW = chunkNeighbours[0 .. neighbourMetrics.centreIndex],
		neighboursSE = chunkNeighbours[(neighbourMetrics.centreIndex + 1) .. $];

		neighboursNW[] = null;
		neighboursSE[] = null;
		chunkNeighbours[neighbourMetrics.centreIndex] = thisChunk;

		foreach (c ; chain(leadingChunks[($-neighboursNW.length) .. $], laggingChunks[0 .. neighboursSE.length]).filter!"a !is null"()) {
			CoordXZ delta = c.coord - thisChunk.coord;
			long index = (cast(long) (neighbourMetrics.centreIndex) * delta.z) + delta.x + neighbourMetrics.deltaIndexShift;
			if (index >= 0 && index < chunkNeighbours.length) {
				chunkNeighbours[cast(size_t) index] = c;
			}
		}

	}

	void returnChunk(Chunk chunk)
	in {
		assert(chunk !is null);
	}
	body
	{
		immutable(ubyte)[] stream = null;
		try {
			if (chunk.modified) stream = chunk.flatten().assumeUnique();
		}
		catch (Exception e) {
			debug(dc13Threads3) stderr.writefln("[WT%d] %s thrown when flattening chunk %s: %s", workerThreadId, typeid(e), thisChunk.coord, e.msg);
		}
		debug(dc13Threads3) stderr.writefln("[WT%d] Sending chunk %s back to MT from state %d", workerThreadId, chunk.coord, state);
		parentTid.send(ChunkCheckinMsg(workerThreadId, chunk.coord, stream, !chunkStreamEmpty));
	}

	/// Spawned threads start here.
	static void launch(Tid parentTid_,immutable(ClassInfo) classInfo_, Dimension dimension_, ubyte workerThreadId_)
	{
		thisWT = new WT(parentTid_, rebindable(classInfo_), dimension_, workerThreadId_, State.Inactive);
		thisWT.workerLobby();
	}

	// Helps with debugging
	debug void printChunkLineState()
	{
		stderr.writefln("[WT%d] LDC/TC/LGC:\n%s %s %s", workerThreadId, leadingChunks.map!q{a is null ? "." : "*"}().join(""), thisChunk is null ? "." : "*", laggingChunks.map!q{a is null ? "." : "*"}().join(""));
	}

}

private WT* thisWT;
