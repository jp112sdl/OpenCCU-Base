# Makefile for rfd

ROMFSINST = /usr/bin/romfs-inst.sh

TARGET = crypttool

LIBELVUTILSPATH = $(realpath ../elvutils)
LIBELVUTILS = elvutils

#OPENSSL=-L ../openssl
OPENSSL=""
#OPENSSLINC=-I../openssl/include
OPENSSLINC=""

TARGETOBJS = $(TARGET).o \
		crypttoolconfig.o

CC = $(CROSS)g++
CXX = $(CROSS)g++
LD = $(CROSS)g++
CXX_FLAGS += -std=c++11 -D_TIME_BITS=64 -D_FILE_OFFSET_BITS=64 -O2 -g $(OPENSSLINC) -I$(LIBELVUTILSPATH) -Wall
LD_FLAGS += -L$(LIBELVUTILSPATH) -l$(LIBELVUTILS) -L./ $(OPENSSL) -lcrypto -lpthread
STRIP = $(CROSS)strip

all: depends $(TARGET)

$(TARGET): $(TARGETOBJS)
	$(CXX) -o $(TARGET) $(TARGETOBJS) $(LD_FLAGS)
	cp -f $(TARGET) $(TARGET).debug || true
	$(STRIP) $(TARGET)

%.o: %.cpp
	$(CXX) $(CXX_FLAGS) -c -o $@ $<

%.o: %.c
	$(CXX) $(CXX_FLAGS) -c -o $@ $<

install: $(TARGET)
	$(STRIP) $(TARGET)
	$(ROMFSINST) /bin/$(TARGET)
	$(ROMFSINST) config.txt /etc/config_templates/crypttool.cfg

depends:
	make -C $(LIBELVUTILSPATH)

clean_libs:
	make clean -C $(LIBELVUTILSPATH)

clean: clean_libs
	rm -rf *.o
	rm -rf $(TARGET)
