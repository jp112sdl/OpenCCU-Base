/*
 * Network.cpp
 *
 *  Created on: 18.01.2013
 *      Author: willms
 */

#include "Network.h"
#include <fcntl.h>
#include <unistd.h>
#include <Logger.h>

Network::Network() :
		netState(Disconnected), linkFileErrorOutput(false), ipFileErrorOutput(
				false), internetFileErrorOutput(false) {
	// TODO Automatisch generierter Konstruktorstub

}

Network::~Network() {
	// TODO !CodeTemplates.destructorstub.tododesc!
}

bool Network::isInfoPending() {
	int hasLinkFile, hasIPFile, hasInternetFile;
	this->netState = Disconnected;
	hasLinkFile = open("/var/status/hasLink", O_RDONLY);
	if (hasLinkFile > 0) {
		this->netState = Network::LinkUp;
		linkFileErrorOutput = false;
		close(hasLinkFile);
	} else {
		if (!linkFileErrorOutput) {
			LOG(Logger::LOG_DEBUG,
					"Network::CheckNetState(): can't open hasLink file");
			linkFileErrorOutput = true;
		}
		return true;
	}
	hasIPFile = open("/var/status/hasIP", O_RDONLY);
	if (hasIPFile > 0) {
		this->netState = Network::IP;
		ipFileErrorOutput = false;
		close(hasIPFile);
	} else {
		if (!ipFileErrorOutput) {
			LOG(Logger::LOG_DEBUG,
					"Network::CheckNetState(): can't open hasIP file");
			ipFileErrorOutput = true;
		}
		return true;
	}
	hasInternetFile = open("/var/status/hasInternet", O_RDONLY);
	if (hasInternetFile > 0) {
		this->netState = Network::InternetAvailable;
		internetFileErrorOutput = false;
		close(hasInternetFile);
	} else {
		if (!internetFileErrorOutput) {
			LOG(Logger::LOG_DEBUG,
					"Network::CheckNetState(): can't open hasInternet file");
			internetFileErrorOutput = true;
		}
		return true;
	}

	return true;
}

Network::NetworkState Network::getNetState() {
	return this->netState;
}
