# Makefile for devicetype xml files

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

RFD_DEVICETYPES_DATA_DIR = $(CCU2_DATA_DIR)/rfd/devicetypes
RFD_DEVICETYPES_OUT_DIR = $(DEVICETYPES_OUT_DIR)
#	@echo Stripping $(T);
DEVXMLOBJS=$(shell ls *.xml)

#all: prepare $(DEVXMLTARGETOBJS)
#	@- $(foreach T, $(DEVXMLTARGETOBJS),\
#	echo "Stripping $(T)";\
#	java -jar $(PROJECT_DIR)/build-tools/bidcos-devicetype-strip.jar $(T) -o $(RFD_DEVICETYPES_OUT_DIR)/$(T) $(DEVICETYPE_STIRP_FLAGS);)

all: prepare $(patsubst %, $(RFD_DEVICETYPES_OUT_DIR)/%, $(DEVXMLOBJS))

$(patsubst %, $(RFD_DEVICETYPES_OUT_DIR)/%, $(DEVXMLOBJS)): $(DEVXMLOBJS)
	@echo "Stripping $@"
	java -jar $(PROJECT_DIR)/build-tools/bidcos-devicetype-strip.jar $(patsubst $(RFD_DEVICETYPES_OUT_DIR)/%, %, $@) $(DEVICETYPE_STRIP_OPTIONS) -o $@ 


prepare: 
	mkdir -p $(RFD_DEVICETYPES_OUT_DIR)

configure:
	rm -f $(LOCAL_CONFIG_FILE)
	touch $(LOCAL_CONFIG_FILE)
	echo "PROJECT_DIR=$(PROJECT_DIR)" >> $(LOCAL_CONFIG_FILE)
	echo "PLATFORM=$(PLATFORM)" >> $(LOCAL_CONFIG_FILE)
	
info:
	@echo ""
	@echo "**************************"
	@echo "* MODULE $(TARGET)"
	@echo "**************************"
	@echo "* PROJECT_DIR = $(PROJECT_DIR)"
	@echo "* TARGET_DIR  = $(TARGET_DIR)"
	@echo "* OUT_DIR     = $(RFD_DEVICETYPES_OUT_DIR)"
	@echo "**************************"
	@echo ""

clean:
	rm -rf $(RFD_DEVICETYPES_OUT_DIR)
