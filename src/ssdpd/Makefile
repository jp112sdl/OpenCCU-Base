# Makefile for TARGET extension

ROMFSINST = /usr/bin/romfs-inst.sh

# Load PROJECT_DIR and PLATFORM from local configuration file
LOCAL_CONFIG_FILE=config.mk
ifneq ($(wildcard $(LOCAL_CONFIG_FILE)),)
include $(LOCAL_CONFIG_FILE)
CONFIGURE=
else
CONFIGURE=configure
endif

# Is PROJECT_DIR specified?
ifeq ($(PROJECT_DIR),)
$(error "missing PROJECT_DIR, run make PROJECT_DIR=<project dir>")
endif

# Is PLATFORM specified?
ifeq ($(PLATFORM),)
$(error "missing PLATFORM, run make PLATFORM=<platform>")
endif

# Load project configuration file
PROJECT_CONFIG_FILE = $(PROJECT_DIR)/platform/$(PLATFORM).mk
ifneq ($(wildcard $(PROJECT_CONFIG_FILE)),)
include $(PROJECT_CONFIG_FILE)
else
$(error "missing project configuration; is PLATFORM=$(PLATFORM) valid?")
endif

TARGET = ssdpd

TARGETOBJS = $(TARGET.o)

LIBELVUTILSPATH = ../elvutils
LIBELVUTILS = elvutils

CC = $(CROSS)g++
CXX = $(CROSS)g++
STRIP = $(CROSS)strip
CXXFLAGS +=  -O2 -I$(LIBELVUTILSPATH) -Wall -Wstrict-prototypes
LDFLAGS += -L$(LIBELVUTILSPATH) -l$(LIBELVUTILS) -lpthread

all: $(TARGET)

$(TARGET): $(TARGETOBJS)

install: $(TARGET)
	$(STRIP) $(TARGET)
	$(ROMFSINST) /bin/$(TARGET)
	
info:
	@echo ""
	@echo "**************************"
	@echo "* MODULE $(TARGET)"
	@echo "**************************"
	@echo "* PROJECT_DIR = $(PROJECT_DIR)"
	@echo "* TARGET_DIR  = $(TARGET_DIR)"
	@echo "* BIN_DIR     = $(BIN_DIR)"
	@echo "**************************"
	@echo ""

clean:
	rm -rf *.o
	rm -rf $(TARGET)
