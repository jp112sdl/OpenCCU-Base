#
#	Makefile -- Build instructions for ATMEL/AT91
#

ROMFSINST = /usr/bin/romfs-inst.sh

ROMFS_DIRS = firmware/hs485types firmware/rftypes www/config firmware/rftypes/replaceMap


export ROMFSDIR 

all:

install:
	for i in $(ROMFS_DIRS); do \
		[ -d $(ROMFSDIR)/$$i ] || mkdir -p $(ROMFSDIR)/$$i; \
	done
	cp replaceMap/rfReplaceMap.xml $(ROMFSDIR)/firmware/rftypes/replaceMap/

	find rftypes/*.xml -type f -exec java -jar ../build-tools/bidcos-devicetype-strip.jar \{\} -o $(ROMFSDIR)/firmware/\{\} \;
	chmod -R 755 $(ROMFSDIR)/firmware/rftypes
	
	find hs485types/*.xml -type f -exec java -jar ../build-tools/bidcos-devicetype-strip.jar \{\} -o $(ROMFSDIR)/firmware/\{\} \;
	chmod -R 755 $(ROMFSDIR)/firmware/hs485types
		
		
	
	$(ROMFSINST) -p 755 /www/config/st_values.cgi
	$(ROMFSINST) -p 755 /www/config/st_values.js

clean:

