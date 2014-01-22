SRCDIR := disasterclass
LIBDIR := .
OBJDIR_DEBUG := ../Build/Objects/Debug
OBJDIR_RELEASE := ../Build/Objects/Release
DMD := $(DMDPATH)/dmd

UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
PLATFORM := Mac
endif
ifeq ($(UNAME), Linux)
PLATFORM := Linux
endif

MODULES = versioninfo support vectors nbt region chunk world data biomedata parallel validate main
FILTERS = stoneage atlantis
MODULES += $(addprefix filters/,$(FILTERS))

VERSION = $(shell ./version_tool)

SOURCES := $(addprefix $(SRCDIR)/,$(addsuffix .d,$(MODULES)))
OBJECTS_DEBUG := $(addprefix $(OBJDIR_DEBUG)/,$(addsuffix .o,$(MODULES)))
OBJECTS_RELEASE := $(addprefix $(OBJDIR_RELEASE)/,$(addsuffix .o,$(MODULES)))

APPDIR_DEBUG = ../Build
APPDIR_RELEASE = ../Build/Release_Staging

ARCHFLAG_DEBUG := -m64
ARCHFLAG := -m64

COMPILEFLAGS = -property
COMPILEFLAGS_DEBUG := -unittest -g $(ARCHFLAG_DEBUG) -debug -debug=dc13Lighting
COMPILEFLAGS_RELEASE := -O -Dd../Build/API_Documentation -release $(ARCHFLAG)

LINKFLAGS_DEBUG :=

all: cma_debug cma_release

cma_debug: version_tool $(OBJECTS_DEBUG)
	# $(shell mkdir $(APPDIR_DEBUG)/$(VERSION))
	$(DMD) -of$(APPDIR_DEBUG)/Disasterclass-debug $(ARCHFLAG_DEBUG) $(LINKFLAGS_DEBUG) $(OBJECTS_DEBUG)

cma_release: itemdata version_tool
	$(shell mkdir $(APPDIR_RELEASE)/$(VERSION))
	$(DMD) -of$(OBJDIR_RELEASE)/Disasterclass.o $(ARCHFLAG) $(COMPILEFLAGS) $(COMPILEFLAGS_RELEASE) -c $(SOURCES)
	$(DMD) -of$(APPDIR_RELEASE)/$(VERSION)/Disasterclass $(ARCHFLAG) $(COMPILEFLAGS) $(COMPILEFLAGS_RELEASE) $(OBJDIR_RELEASE)/Disasterclass.o
	#rm $(APPDIR_RELEASE)/$(VERSION)/Disasterclass*.o

$(OBJDIR_DEBUG)/%.o: $(SRCDIR)/%.d
	$(DMD) -of$@ -I$(LIBDIR) $(COMPILEFLAGS) $(COMPILEFLAGS_DEBUG) -c $<

# $(OBJDIR_RELEASE)/%.o: $(SRCDIR)/%.d
# 	$(DMD) -of$@ -I$(LIBDIR) $(COMPILEFLAGS) $(COMPILEFLAGS_RELEASE) -c $<

itemdata:
	python data/data_processor.py $(SRCDIR)/data.d data/data.json

version_tool: $(SRCDIR)/versioninfo.d
	$(DMD) -ofversion_tool -property -version=dc13PrintVersion $(SRCDIR)/versioninfo.d
	rm version_tool.o


clean:
	-rm -r $(OBJECTS_DEBUG)
	-rm -r $(OBJECTS_RELEASE)
	-rm $(APPDIR_DEBUG)/Disasterclass $(APPDIR_RELEASE)/$(VERSION)/Disasterclass
