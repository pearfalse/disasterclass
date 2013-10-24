# Disasterclass
Disasterclass is a tool to process a Minecraft world. The plan is to let you use it to age your mansion by a thousand years, throw your castle underwater, or run your own filters.

## Building
Disasterclass is written in [the D programming language](http://dlang.org/), and you'll need DMD v2.063 or later (in your path as `dmd`). You'll also need [Python](http://python.org/) to compile the item data.

After checking out the source, move to the `src/` folder and type `make cma_release` to build a release version in `Build/Release_Staging/<version>`. This builds an x64 version by default. If you want a 32-bit version, change the line

	ARCHFLAG := -m64

to

	ARCHFLAG := -m32

and rebuild.

Building has only been extensively tested on OS X, but Disasterclass should also compile on Windows (if you can get a working build script) and Linux.

## Running
**Disasterclass changes a world in-place. Back up your world before running.**

Disasterclass currently runs from the command line. (I apologise in advance.) Type `./Disasterclass` to get a list of what you can do. Commands follow this form:

	./Disasterclass <command-name> --world <path-to-Minecraft-world>
	
The main function to age a world is `stoneage`.

## Documentation
Developer docs are automatically built from source on release builds in `Build/API_Documentation`. You can find in-depth documentation on how Disasterclass's multicore dispatch works at [Documentation/Multicore.md](Documentation/Multicore.md).

## License
Disasterclass is licensed under terms of the Mozilla Public License, version 2.0. See [LICENSE.txt](LICENSE.txt) or [Mozilla's web copy](http://www.mozilla.org/MPL/2.0/).

## To Improve
Disasterclass is far from finished, and there's plenty that needs refinement. The chunk loading/saving and multicore architecture are pretty much there; the light recalculation isn't on par with Minecraft (also it is *crazy slow*). The current world filters are quite basic at the moment, and could benefit from refinement — this is an aesthetic call, however.

