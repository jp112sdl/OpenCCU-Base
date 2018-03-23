/*
 * InfoLed.h
 *
 *  Created on: 18.01.2013
 *      Author: willms
 */

#ifndef INFOLED_H_
#define INFOLED_H_
#include <string>
#include "led.h"
#include "ServiceMessage.h"
#include "AlarmMessage.h"
#include "UpdateAvailable.h"
#include "MessageParser.h"
#include "RFLGWInfoLED.h"

class InfoLed {
public:
	InfoLed();
	virtual ~InfoLed();
	void updateLedState();
	bool checkMessage(std::string &msg);

private:
	led infoLed;
	const unsigned long infoLedRefreshTime;
	unsigned long nextInfoUpdate;
	ServiceMessage service;
	AlarmMessage alarm;
	UpdateAvailable update;
	MessageParser parser;
	RFLGWInfoLED rflgwInfoLed;
};

#endif /* INFOLED_H_ */
